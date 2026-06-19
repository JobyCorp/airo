defmodule Airo.Routing.Classifier do
  @moduledoc """
  Computes a routing tier (`route.class`) for a routed alias by classifying the
  incoming prompt (DESIGN-chat-routing.md, T2).

  `class_for/2` reads the alias's `router_config`, extracts the prompt text, asks
  the configured `:classify` deployment (a zero-shot NLI model via the Infinity
  adapter) for an entailment score per label, and returns the first label whose
  score clears its `min` threshold — falling back to `default_class` when nothing
  crosses.

  Infinity runs only the model's fixed NLI head (it ignores `candidate_labels`),
  so we build the premise+hypothesis pair ourselves:
  `input = premise <> " " <> hypothesis`, batch every label into one `/classify`
  call, and read each label's `entailment` score *by label* (order within a row is
  not positional). See §10 for the live validation.

  Everything is **fail-open**: a bad config, empty prompt, upstream error, or
  timeout yields `:skip` / `{:error, _}` and the gateway leaves routing untouched.
  The upstream call is bounded by `router_config["timeout_ms"]`.

  This deliberately bypasses `Gateway.resolve/3` + `run/1` (no auth/ClientKey, no
  failover, no usage record) — it's a fast internal call and fail-open is the
  safety net. It resolves the classifier via `Routing.candidates/3` directly (not
  `Gateway.alias_target/3`), so a routed classifier alias cannot recurse.
  """

  alias Airo.{Adapter, Config, Registry, Routing}
  alias Airo.Adapter.Context

  @default_template "This request requires {}."
  @default_input "last_user"
  @default_class "edge"
  @default_timeout_ms 200

  @doc """
  Predicted tier for `alias_` given the request `params` (OpenAI-shaped).

  Returns `{:ok, class, scores}` (the chosen `Deployment.class` string plus the
  per-class entailment map, surfaced for the T5 observability log), `:skip` when
  there is no classifiable text, or `{:error, reason}` on bad config / upstream
  failure / timeout. The caller treats `:skip` and `{:error, _}` as fail-open.
  """
  @spec class_for(Config.Alias.t(), map()) ::
          {:ok, String.t(), map()} | :skip | {:error, term()}
  def class_for(%Config.Alias{} = alias_, params) when is_map(params) do
    with {:ok, config} <- parse_config(alias_.router_config),
         {:ok, premise} <- extract_input(params, config),
         {:ok, scores} <- score(config, premise) do
      {:ok, decide(config, scores), scores}
    end
  rescue
    # Total by contract: a DB / resolve / decode explosion fails open rather than
    # raising into the caller (enforce runs this in the request process, so an
    # unhandled raise would 500 a chat request — exactly what must never happen).
    e -> {:error, {:exception, e}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  ## Config

  defp parse_config(rc) when is_map(rc) do
    classifier = rc["classifier"]
    labels = normalize_labels(rc["labels"])

    if is_binary(classifier) and labels != [] do
      {:ok,
       %{
         classifier: classifier,
         labels: labels,
         template: as_string(rc["hypothesis_template"], @default_template),
         input: as_string(rc["input"], @default_input),
         default_class: as_string(rc["default_class"], @default_class),
         timeout_ms: as_pos_int(rc["timeout_ms"], @default_timeout_ms)
       }}
    else
      {:error, :bad_config}
    end
  end

  defp parse_config(_), do: {:error, :bad_config}

  # Keep only well-formed `{label, class, min}` entries; order is preserved
  # (highest tier first → first over `min` wins, per the decision step).
  defp normalize_labels(labels) when is_list(labels) do
    for %{"label" => l, "class" => c, "min" => m} <- labels,
        is_binary(l) and is_binary(c) and is_number(m),
        do: %{label: l, class: c, min: m}
  end

  defp normalize_labels(_), do: []

  defp as_string(v, _default) when is_binary(v), do: v
  defp as_string(_v, default), do: default

  defp as_pos_int(v, _default) when is_integer(v) and v > 0, do: v
  defp as_pos_int(_v, default), do: default

  ## Input extraction

  defp extract_input(params, %{input: "all"}) do
    (params["messages"] || [])
    |> Enum.map(&message_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> finalize()
  end

  defp extract_input(params, _last_user) do
    (params["messages"] || [])
    |> Enum.filter(&(is_map(&1) and &1["role"] == "user"))
    |> List.last()
    |> case do
      nil -> ""
      msg -> message_text(msg)
    end
    |> finalize()
  end

  defp finalize(text) do
    case String.trim(text) do
      "" -> :skip
      trimmed -> {:ok, trimmed}
    end
  end

  # Text content only; image/other parts are dropped (T2 step 2).
  defp message_text(%{"content" => content}) when is_binary(content), do: content

  defp message_text(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join(" ", & &1["text"])
  end

  defp message_text(_), do: ""

  ## Scoring (branch B — build NLI pairs, batch, read entailment by label)

  defp score(config, premise) do
    with {:ok, candidate} <- resolve_classifier(config.classifier),
         {:ok, adapter, ctx} <- build_call(candidate) do
      inputs = Enum.map(config.labels, &(premise <> " " <> render(config.template, &1.label)))

      run_bounded(config.timeout_ms, fn ->
        case adapter.classify(%{"input" => inputs}, ctx) do
          {:ok, %{"data" => rows}}
          when is_list(rows) and length(rows) == length(config.labels) ->
            {:ok, zip_scores(config.labels, rows)}

          {:ok, _malformed} ->
            {:error, :malformed_response}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  defp resolve_classifier(name) do
    case Config.get_alias_by_name(name) do
      nil ->
        {:error, :bad_config}

      alias_ ->
        case Routing.candidates(alias_, %{}, :classify) do
          {:ok, [candidate | _]} -> {:ok, candidate}
          {:ok, []} -> {:error, :no_classifier_candidate}
          {:error, _} = err -> err
        end
    end
  end

  defp build_call(%{provider: provider, deployment: deployment}) do
    with {:ok, adapter} <- Registry.fetch(provider.adapter_type),
         true <- Adapter.supports?(adapter, :classify) do
      {:ok, adapter, Context.new(provider, deployment: deployment)}
    else
      false -> {:error, {:unsupported_capability, :classify}}
      {:error, _} = err -> err
    end
  end

  defp render(template, label), do: String.replace(template, "{}", label)

  defp zip_scores(labels, rows) do
    labels
    |> Enum.zip(rows)
    |> Map.new(fn {label, row} -> {label.class, entailment(row)} end)
  end

  defp entailment(row) when is_list(row) do
    case Enum.find(row, &(is_map(&1) and &1["label"] == "entailment")) do
      %{"score" => s} when is_number(s) -> s
      _ -> 0.0
    end
  end

  defp entailment(_), do: 0.0

  ## Decision — first label (highest tier first) whose score clears `min`

  defp decide(config, scores) do
    Enum.find_value(config.labels, config.default_class, fn label ->
      if Map.get(scores, label.class, 0.0) >= label.min, do: label.class
    end)
  end

  ## Timeout — bound only the upstream call; never crash the caller

  defp run_bounded(timeout_ms, fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          e -> {:error, {:exception, e}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end
end
