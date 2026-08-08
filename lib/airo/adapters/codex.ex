defmodule Airo.Adapters.Codex do
  @moduledoc """
  Adapter for the ChatGPT Codex backend — OpenAI models served by a ChatGPT
  (Codex) subscription rather than a platform API key, presented OpenAI-shaped
  like every other adapter (DESIGN §6).

  Accepts an OpenAI `/chat/completions` request, translates it to the
  Responses API the backend speaks (`Airo.Adapters.Codex.Translate`), manages
  the "Sign in with ChatGPT" OAuth tokens (`Airo.Adapters.Codex.OAuth`;
  initial sign-in via `Airo.Adapters.Codex.Login` on the provider page), and
  normalizes the SSE stream back to OpenAI deltas. The backend only streams,
  so the non-streaming `chat/2` folds the stream and translates the terminal
  `response.completed` object.

  Provider `base_url` should be `https://chatgpt.com/backend-api/codex`.
  Request headers and catalog discovery are configurable (`models`, when set,
  short-circuits the live `/models` lookup):

      config :airo, Airo.Adapters.Codex,
        beta: "responses=experimental",
        originator: "codex_cli_rs",
        client_version: "2.0.0",
        models: ["gpt-5.6-terra", ...]
  """
  @behaviour Airo.Adapter

  alias Airo.Adapter.Context
  alias Airo.Adapters.Codex.{OAuth, Translate}
  alias Airo.Config.{Deployment, Provider}
  alias Airo.Transport

  @default_beta "responses=experimental"
  @default_originator "codex_cli_rs"
  # The `/models` catalog is version-gated; any recent client version sees the
  # full list for the account's plan.
  @default_client_version "2.0.0"

  @impl Airo.Adapter
  def chat(params, %Context{provider: provider} = ctx) when is_map(params) do
    with {:ok, headers} <- headers(provider) do
      body = request_body(params, ctx)

      # The backend serves streams only. Collect the per-item `done` recaps as
      # well as the terminal event: the terminal `response.completed` object
      # arrives with an *empty* `output` on this backend, so the recaps are
      # what actually carry the content.
      collect = fn
        %{"type" => "response.output_item.done", "item" => item}, acc ->
          %{acc | items: [item | acc.items]}

        %{"type" => "response.completed", "response" => response}, acc ->
          %{acc | terminal: {:completed, response}}

        %{"type" => "response.failed", "response" => response}, acc ->
          %{acc | terminal: {:failed, response}}

        _event, acc ->
          acc
      end

      init = %{items: [], terminal: nil}

      case Transport.stream(ctx, "/responses", body, init, collect, headers: headers) do
        {:ok, %{terminal: {:completed, response}, items: items}} ->
          {:ok, response |> with_output(Enum.reverse(items)) |> Translate.response()}

        {:ok, %{terminal: {:failed, response}}} ->
          {:error, {:upstream_failed, response["error"] || response}}

        {:ok, %{terminal: nil}} ->
          {:error, :no_response}

        {:error, reason, _acc} ->
          {:error, reason}
      end
    end
  end

  defp with_output(%{"output" => [_ | _]} = response, _items), do: response
  defp with_output(response, items), do: Map.put(response, "output", items)

  @impl Airo.Adapter
  def stream(params, %Context{provider: provider} = ctx, acc, reducer) when is_map(params) do
    case headers(provider) do
      {:ok, headers} ->
        # Each Responses SSE event becomes zero or more OpenAI delta chunks,
        # which we fold through the caller's reducer.
        translating = fn event, current ->
          event |> Translate.stream_event() |> Enum.reduce(current, reducer)
        end

        Transport.stream(ctx, "/responses", request_body(params, ctx), acc, translating,
          headers: headers
        )

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  @impl Airo.Adapter
  def list_models(%Context{provider: provider} = ctx) do
    with :live <- configured_models(),
         {:ok, headers} <- headers(provider),
         {:ok, %{status: status, body: %{"models" => models}}} when status in 200..299 <-
           Transport.get(ctx, "/models?client_version=" <> client_version(), headers: headers) do
      {:ok, for(%{"slug" => slug} <- models, is_binary(slug), do: slug)}
    else
      {:ok, models} when is_list(models) -> {:ok, models}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp configured_models do
    case Keyword.get(config(), :models) do
      models when is_list(models) -> {:ok, models}
      _ -> :live
    end
  end

  defp request_body(params, ctx) do
    params
    |> Translate.request(model(ctx.deployment, params))
    |> Map.put("stream", true)
  end

  defp model(%Deployment{model_name: model}, _params) when is_binary(model), do: model
  defp model(_deployment, params), do: params["model"]

  # Subscription auth only: the OAuth bearer plus the ChatGPT account id the
  # backend requires. An API key belongs on a plain `:openai` provider instead.
  defp headers(%Provider{auth_kind: :oauth} = provider) do
    with {:ok, token} <- OAuth.ensure_fresh(provider),
         {:ok, account_id} <- OAuth.account_id(token) do
      {:ok,
       [
         {"authorization", "Bearer " <> token},
         {"chatgpt-account-id", account_id},
         {"openai-beta", beta()},
         {"originator", originator()}
       ]}
    end
  end

  defp headers(_provider), do: {:error, :oauth_required}

  defp config, do: Application.get_env(:airo, __MODULE__, [])
  defp beta, do: Keyword.get(config(), :beta, @default_beta)
  defp originator, do: Keyword.get(config(), :originator, @default_originator)
  defp client_version, do: Keyword.get(config(), :client_version, @default_client_version)
end
