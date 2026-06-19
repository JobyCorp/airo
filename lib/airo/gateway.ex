defmodule Airo.Gateway do
  @moduledoc """
  Request entry point: alias resolution → scope authorization → routing →
  param normalization → adapter dispatch with failover (DESIGN §9, §13).

  `resolve/3` makes the policy decisions and returns a *plan* — an ordered list
  of dispatch `attempts` (the failover order from `Airo.Routing`), each with its
  own adapter, context, and per-candidate normalized body. `run/1` (chat) and
  `run_stream/4` walk that list, advancing to the next attempt on a *retryable*
  failure (upstream 5xx / transport error), never on a 4xx. Streaming can only
  fail over before the first byte is committed.

  Transparency reflects the candidate that actually *served*, with
  `fallback_used` set when an earlier attempt was skipped.
  """

  require Logger

  alias Airo.Adapter
  alias Airo.Adapter.Context
  alias Airo.Config
  alias Airo.Config.{Alias, ClientKey, Deployment, Provider}
  alias Airo.Gateway.Params
  alias Airo.Gateway.Vision
  alias Airo.Health
  alias Airo.Registry
  alias Airo.Routing
  alias Airo.Routing.Classifier

  @type attempt :: %{
          adapter: module(),
          provider: Provider.t(),
          deployment: Deployment.t(),
          context: Context.t(),
          body: map()
        }

  @type plan :: %{
          model: String.t(),
          capability: atom(),
          usage_capability: atom(),
          attempts: [attempt(), ...]
        }

  @type info :: %{served: attempt(), fallback_used: boolean()}

  @type error ::
          :missing_model
          | {:model_not_found, String.t()}
          | {:forbidden, String.t()}
          | :no_deployment
          | :selected_binding_unavailable
          | {:no_adapter, atom()}
          | {:unsupported_capability, atom()}
          | {:http_error, non_neg_integer(), term()}
          | {:transport_error, term()}

  @doc """
  Resolve a request to a dispatch plan for `capability` (`:chat` | `:stream` |
  `:embed` | `:rerank` | `:speech` | `:transcribe`).

  `model` may be either an **alias** name (resolved via `Airo.Routing` — strategy,
  health, fallback, strict pin) or a **concrete deployment model id** (resolved to
  the enabled deployment(s) of the matching capability, health-ordered as
  failover candidates). Aliases win when the name matches one. After authorizing
  the key's scope against `model`, builds a dispatch attempt per candidate whose
  adapter supports the capability.
  """
  @spec resolve(map(), ClientKey.t(), atom()) :: {:ok, plan()} | {:error, error()}
  def resolve(params, %ClientKey{} = client_key, capability) when is_map(params) do
    resource = resource_capability(capability, params)

    with {:ok, model} <- fetch_model(params),
         :ok <- authorize(client_key, model),
         {:ok, resolution} <- resolve_target(model, params, resource),
         {:ok, attempts} <-
           build_attempts(resolution.candidates, resolution.alias, params, capability) do
      {:ok,
       %{
         model: model,
         capability: capability,
         usage_capability: resolution.usage_capability,
         attempts: attempts
       }}
    end
  end

  @doc """
  Run a non-streaming chat completion. Convenience over `resolve/3` + `run/1`,
  returning just the OpenAI-shaped response body.
  """
  @spec chat(map(), ClientKey.t()) :: {:ok, map()} | {:error, error()}
  def chat(params, %ClientKey{} = client_key) when is_map(params) do
    with {:ok, plan} <- resolve(params, client_key, :chat),
         {:ok, body, _info} <- run(plan) do
      {:ok, body}
    end
  end

  @doc """
  Execute a plan as a non-streaming request, dispatching to the plan's capability
  callback (`:chat`, `:embed`, `:rerank`, `:speech`, `:transcribe`) and failing
  over across attempts on retryable upstream errors. Returns the body plus `info`
  (served attempt + whether a fallback fired).
  """
  @spec run(plan()) :: {:ok, term(), info()} | {:error, error()}
  def run(%{capability: capability, attempts: attempts}),
    do: run_attempts(attempts, capability, false)

  defp run_attempts([attempt | rest], capability, fallback_used) do
    log_attempt(:info, "gateway.attempt.started", attempt, capability, fallback_used)

    case apply(attempt.adapter, capability, [attempt.body, attempt.context]) do
      {:ok, body} ->
        mark_health(attempt, :ok)
        log_attempt(:info, "gateway.attempt.succeeded", attempt, capability, fallback_used)
        {:ok, body, %{served: attempt, fallback_used: fallback_used}}

      {:error, reason} ->
        mark_health(attempt, reason)

        log_attempt(:warning, "gateway.attempt.failed", attempt, capability, fallback_used,
          error: inspect(reason)
        )

        if retryable?(reason) and rest != [],
          do: run_attempts(rest, capability, true),
          else: {:error, reason}
    end
  end

  @doc """
  Execute a plan as a streaming completion, folding each delta into `acc` via
  `reducer`. Fails over to the next attempt only while `committed?.(acc)` is
  false (nothing emitted yet). Returns `{:ok, acc, info}`, or
  `{:partial_error, reason, acc}` once output has begun, or `{:error, reason,
  acc}` when every attempt failed before emitting.
  """
  @spec run_stream(plan(), acc, (map(), acc -> acc), (acc -> boolean())) ::
          {:ok, acc, info()} | {:partial_error, error(), acc} | {:error, error(), acc}
        when acc: term()
  def run_stream(%{attempts: attempts}, acc, reducer, committed?) do
    stream_attempts(attempts, acc, reducer, committed?, false)
  end

  defp stream_attempts([attempt | rest], acc, reducer, committed?, fallback_used) do
    log_attempt(:info, "gateway.stream_attempt.started", attempt, :stream, fallback_used)

    case attempt.adapter.stream(attempt.body, attempt.context, acc, reducer) do
      {:ok, acc} ->
        log_attempt(:info, "gateway.stream_attempt.succeeded", attempt, :stream, fallback_used)
        {:ok, acc, %{served: attempt, fallback_used: fallback_used}}

      {:error, reason, acc} ->
        cond do
          committed?.(acc) ->
            # Output already began, so the host responded — count it healthy.
            mark_health(attempt, :ok)

            log_attempt(
              :warning,
              "gateway.stream_attempt.partial_error",
              attempt,
              :stream,
              fallback_used,
              error: inspect(reason)
            )

            {:partial_error, reason, acc}

          true ->
            mark_health(attempt, reason)

            log_attempt(
              :warning,
              "gateway.stream_attempt.failed",
              attempt,
              :stream,
              fallback_used,
              error: inspect(reason)
            )

            if retryable?(reason) and rest != [],
              do: stream_attempts(rest, acc, reducer, committed?, true),
              else: {:error, reason, acc}
        end
    end
  end

  # Live health feedback. A real dispatch is a stronger signal than the periodic
  # prober, so record its outcome: a response (even 4xx) means the host is
  # reachable → :up; a transport failure or 5xx → :down. Mirrors the prober's
  # classify/2. Other reasons (e.g. config-shaped errors) carry no host signal.
  defp mark_health(%{deployment: deployment, provider: provider}, outcome) do
    case outcome do
      :ok ->
        Health.mark_deployment(deployment, provider, :up, source: :dispatch)

      {:http_error, status, _} when status >= 500 ->
        Health.mark_deployment(deployment, provider, :down,
          source: :dispatch,
          reason: "http_#{status}"
        )

      {:http_error, status, _} ->
        Health.mark_deployment(deployment, provider, :up,
          source: :dispatch,
          reason: "http_#{status}"
        )

      {:transport_error, reason} ->
        Health.mark_deployment(deployment, provider, :down,
          source: :dispatch,
          reason: reason_code(reason)
        )

      _ ->
        :ok
    end
  end

  @doc """
  Transparency metadata for the served attempt (DESIGN §5.1): which concrete
  provider/model served, whether a fallback fired, and (when known) latency.
  """
  @spec transparency(attempt(), keyword()) :: map()
  def transparency(%{provider: provider, deployment: deployment}, extra \\ []) do
    %{
      "provider" => provider.name,
      "model" => deployment.model_name,
      "deployment_id" => deployment.id,
      "fallback_used" => Keyword.get(extra, :fallback_used, false)
    }
    |> maybe_put("latency_ms", Keyword.get(extra, :latency_ms))
  end

  ## Internal

  defp fetch_model(params) do
    case params["model"] do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, :missing_model}
    end
  end

  defp authorize(client_key, model) do
    if ClientKey.scoped?(client_key, model), do: :ok, else: {:error, {:forbidden, model}}
  end

  # An alias name routes via policy; otherwise fall back to a concrete deployment
  # model id. Both filter candidates by the `resource` capability (the resource
  # the client is requesting). Returns candidates + the alias (or nil, for the
  # param-layer) + the capability used for usage records.
  defp resolve_target(model, params, resource) do
    case Config.get_alias_by_name(model) do
      %Alias{} = alias_ -> alias_target(alias_, params, resource)
      nil -> concrete_target(model, resource)
    end
  end

  defp alias_target(alias_, params, resource) do
    route = if is_map(params["route"]), do: params["route"], else: %{}
    route = maybe_classify(alias_, params, route, resource)

    case Routing.candidates(alias_, route, resource) do
      {:ok, []} ->
        {:error, :no_deployment}

      {:ok, candidates} ->
        {:ok, %{candidates: candidates, alias: alias_, usage_capability: resource}}

      {:error, _reason} = error ->
        error
    end
  end

  ## Classification-driven routing (routed aliases) — DESIGN-chat-routing.md, T3/T5

  # Compute `route.class` from the prompt when the alias opts in and the caller
  # left the tier unspecified. Enforce applies the prediction synchronously;
  # shadow logs it from a detached task without touching `route` (no caller
  # latency). Any other case returns `route` unchanged.
  defp maybe_classify(alias_, params, route, resource) do
    if classify?(alias_, route, resource),
      do: run_classification(alias_, params, route),
      else: route
  end

  defp classify?(%Alias{router: :classify}, route, resource)
       when resource in [:chat, :vision],
       do: is_nil(route["class"]) and is_nil(route["binding"])

  defp classify?(_alias, _route, _resource), do: false

  defp run_classification(alias_, params, route) do
    trace_id = Logger.metadata()[:gateway_trace_id]

    case classifier_mode(alias_) do
      "enforce" ->
        {result, latency_ms} = timed(fn -> Classifier.class_for(alias_, params) end)
        log_classified(alias_, result, "enforce", latency_ms, trace_id)
        apply_class(route, result)

      _shadow ->
        # Detached so serving isn't blocked on the classifier round-trip. Reuses
        # the running Task.Supervisor; the task is best-effort and self-contained
        # (`class_for` is fail-open), so it can never affect the request.
        Task.Supervisor.start_child(Airo.Usage.TaskSupervisor, fn ->
          {result, latency_ms} = timed(fn -> Classifier.class_for(alias_, params) end)
          log_classified(alias_, result, "shadow", latency_ms, trace_id)
        end)

        route
    end
  end

  defp classifier_mode(alias_), do: get_in(alias_.router_config, ["mode"]) || "shadow"

  # Only a confident prediction mutates routing; `:skip` / `{:error, _}` leave
  # `route` untouched → no class filter → full priority + failover (fail-open, §4).
  defp apply_class(route, {:ok, class, _scores}), do: Map.put(route, "class", class)
  defp apply_class(route, _result), do: route

  defp timed(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - start}
  end

  # `gateway.route.classified` — the calibration signal (T5). The full prediction
  # is rendered into the *message* so it's readable in any sink (plain console, a
  # homelab log tail) without a metadata-aware formatter, and is also attached as
  # structured metadata for sinks that index it. `applied` is true only when
  # enforce mutated the route.
  defp log_classified(alias_, result, mode, latency_ms, trace_id) do
    applied = mode == "enforce" and match?({:ok, _, _}, result)

    {predicted, scores, summary} =
      case result do
        {:ok, class, raw} -> {class, round_scores(raw), "predicted=#{class}"}
        :skip -> {nil, %{}, "skipped(no_text)"}
        {:error, reason} -> {nil, %{}, "error=#{inspect(reason)}"}
      end

    Logger.info(
      "gateway.route.classified alias=#{alias_.name} #{summary} applied=#{applied} " <>
        "mode=#{mode} scores=#{inspect(scores)} latency_ms=#{latency_ms} trace=#{trace_id}",
      event: "gateway.route.classified",
      alias: alias_.name,
      predicted_class: predicted,
      scores: scores,
      mode: mode,
      applied: applied,
      latency_ms: latency_ms,
      trace_id: trace_id
    )
  end

  defp round_scores(scores), do: Map.new(scores, fn {c, s} -> {c, Float.round(s, 3)} end)

  defp concrete_target(model, resource) do
    case Config.list_deployments_by_model(model, resource) do
      [] ->
        {:error, {:model_not_found, model}}

      deployments ->
        {:ok,
         %{
           candidates: Routing.deployment_candidates(deployments),
           alias: nil,
           usage_capability: resource
         }}
    end
  end

  # The resource a client is requesting — the Deployment capability to filter on,
  # derived from the endpoint protocol + payload. Chat upgrades to `:vision` when
  # the request carries image content (or `route.vision`); the rest map the
  # adapter callback name to its Deployment-enum capability.
  defp resource_capability(cap, params) when cap in [:chat, :stream] do
    if Vision.requires_vision?(params), do: :vision, else: :chat
  end

  defp resource_capability(:embed, _params), do: :embeddings
  defp resource_capability(:transcribe, _params), do: :transcription
  defp resource_capability(other, _params), do: other

  # One dispatch attempt per candidate whose adapter supports the capability,
  # preserving routing order. The body is normalized per-candidate (provider and
  # deployment default-param layers differ across candidates).
  defp build_attempts(candidates, alias_, params, capability) do
    attempts =
      Enum.flat_map(candidates, fn %{provider: provider, deployment: deployment} ->
        with {:ok, adapter} <- Registry.fetch(provider.adapter_type),
             true <- Adapter.supports?(adapter, capability) do
          [
            %{
              adapter: adapter,
              provider: provider,
              deployment: deployment,
              context: Context.new(provider, deployment: deployment),
              body:
                Params.normalize(params, %{
                  provider: provider,
                  deployment: deployment,
                  alias: alias_
                })
            }
          ]
        else
          _ -> []
        end
      end)

    case attempts do
      [] -> {:error, attempts_error(candidates, capability)}
      list -> {:ok, list}
    end
  end

  defp attempts_error(candidates, capability) do
    if Enum.any?(candidates, &match?({:ok, _}, Registry.fetch(&1.provider.adapter_type))),
      do: {:unsupported_capability, capability},
      else: {:no_adapter, hd(candidates).provider.adapter_type}
  end

  defp retryable?({:transport_error, _}), do: true
  defp retryable?({:http_error, status, _}) when status >= 500, do: true
  defp retryable?(_), do: false

  defp log_attempt(level, event, attempt, capability, fallback_used, extra \\ []) do
    metadata =
      [
        capability: capability,
        provider: attempt.provider.name,
        deployment_id: attempt.deployment.id,
        model: attempt.deployment.model_name,
        fallback_used: fallback_used
      ] ++ extra

    Logger.log(level, event, metadata)
  end

  defp reason_code(%{reason: reason}), do: "transport_#{reason}"
  defp reason_code(reason) when is_atom(reason), do: "transport_#{reason}"
  defp reason_code(_reason), do: "transport_error"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
