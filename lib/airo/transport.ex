defmodule Airo.Transport do
  @moduledoc """
  Thin HTTP transport for upstream provider calls — our own wrapper over
  Req/Finch (DESIGN §14, no `openai_ex`). One transport serves both the
  OpenAI-compatible adapters and the bespoke ones.

  Responsibilities kept here so adapters stay declarative:

    - bind requests to the shared `Airo.Finch` instance (per-host pools, §13);
    - join the provider `base_url` with an endpoint path *without* dropping a
      path prefix like `/v1` (the usual `URI.merge` footgun);
    - inject auth headers from the provider's credential/`auth_kind`;
    - thread per-call `:req_options` (e.g. a `Req.Test` plug, timeouts).

  Retries are deliberately **off** here; failover/retry is the routing layer's
  job (S4), so we never double-retry an upstream.
  """

  alias Airo.Adapter.Context
  alias Airo.Config.{Provider, Secret}
  alias Airo.Repo

  @default_receive_timeout 60_000

  @doc """
  Finch pool configuration for the shared `Airo.Finch` instance. Overridable via

      config :airo, Airo.Transport, finch_pools: %{...}

  Finch already pools per `{scheme, host, port}`, so the `:default` config
  applies per provider host; tune specific hosts by adding keys.
  """
  def finch_pools do
    Application.get_env(:airo, __MODULE__, [])
    |> Keyword.get(:finch_pools, %{default: [size: 50, count: 1]})
  end

  @typedoc "Normalized response: decoded body plus status and headers."
  @type response :: %{status: non_neg_integer(), body: term(), headers: map()}

  @doc """
  POST `json` to `path` on the context's provider, returning the normalized
  response or `{:error, exception}` on a transport failure.

  `path` is joined onto the provider `base_url` preserving any path prefix, so a
  base of `http://host/v1` and path `/chat/completions` hits `…/v1/chat/completions`.
  """
  @spec post(Context.t(), String.t(), map(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def post(%Context{} = ctx, path, json, opts \\ []) do
    ctx
    |> build_request(opts)
    |> Req.post(url: full_url(ctx.provider.base_url, path), json: json)
    |> normalize()
  end

  @doc """
  GET `path` on the context's provider (e.g. `/models`), returning the
  normalized response or `{:error, exception}`.
  """
  @spec get(Context.t(), String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def get(%Context{} = ctx, path, opts \\ []) do
    ctx
    |> build_request(opts)
    |> Req.get(url: full_url(ctx.provider.base_url, path))
    |> normalize()
  end

  @doc """
  Stream a POST of `json` to `path`, parsing the upstream Server-Sent Events and
  folding each `data:` JSON event into `acc` via `reducer`. The SSE `[DONE]`
  sentinel terminates the stream and is not forwarded; malformed JSON events are
  skipped.

  Returns `{:ok, acc}` on a 2xx stream, or `{:error, {:http_error, status, body}}`
  / `{:error, {:transport_error, reason}}`. Reuses the shared `Airo.Finch` via
  Req's `:into` streaming, so backpressure and per-host pooling are unchanged.
  """
  @spec stream(Context.t(), String.t(), map(), acc, (map(), acc -> acc), keyword()) ::
          {:ok, acc} | {:error, term(), acc}
        when acc: term()
  def stream(%Context{} = ctx, path, json, acc, reducer, opts \\ []) do
    # Track the live accumulator in the process dictionary so a mid-stream
    # transport drop (where Req returns no response) can still hand it back —
    # the caller needs it to know whether any bytes were already emitted.
    live = {:airo_stream_acc, make_ref()}
    Process.put(live, acc)

    tracked = fn chunk, current ->
      next = reducer.(chunk, current)
      Process.put(live, next)
      next
    end

    init = %{buffer: "", acc: acc, reducer: tracked, err: ""}

    try do
      ctx
      |> build_request(opts)
      |> Req.post(
        url: full_url(ctx.provider.base_url, path),
        json: json,
        into: fn
          {:data, data}, {req, resp} ->
            state = Req.Response.get_private(resp, :airo_sse, init)

            state =
              if resp.status in 200..299,
                do: consume_sse(data, state),
                else: %{state | err: state.err <> data}

            {:cont, {req, Req.Response.put_private(resp, :airo_sse, state)}}

          _other, into_acc ->
            {:cont, into_acc}
        end
      )
      |> case do
        {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
          {:ok, Req.Response.get_private(resp, :airo_sse, init).acc}

        {:ok, %Req.Response{status: status} = resp} ->
          state = Req.Response.get_private(resp, :airo_sse, init)
          {:error, {:http_error, status, decode_error(state.err)}, state.acc}

        {:error, reason} ->
          {:error, {:transport_error, reason}, Process.get(live, acc)}
      end
    after
      Process.delete(live)
    end
  end

  @doc """
  Join an endpoint path onto a base URL without discarding the base's path
  prefix. Both a leading slash on `path` and a trailing slash on `base` are
  tolerated.
  """
  @spec full_url(String.t(), String.t()) :: String.t()
  def full_url(base, path) do
    String.trim_trailing(base, "/") <> "/" <> String.trim_leading(path, "/")
  end

  @doc """
  Auth headers for a provider, resolved from its `auth_kind` and credential
  `Secret`. `:none` → no header; `:api_key`/`:oauth` → `Authorization: Bearer`
  from the (decrypted) secret value. Loads the credential association if needed.
  """
  @spec auth_headers(Provider.t()) :: [{String.t(), String.t()}]
  def auth_headers(%Provider{auth_kind: :none}), do: []

  def auth_headers(%Provider{auth_kind: kind} = provider) when kind in [:api_key, :oauth] do
    case load_credential(provider) do
      %Secret{value: value} when is_binary(value) -> [{"authorization", "Bearer " <> value}]
      _ -> []
    end
  end

  ## Internal

  defp build_request(%Context{} = ctx, opts) do
    req_opts =
      [
        finch: Airo.Finch,
        headers: auth_headers(ctx.provider),
        receive_timeout: @default_receive_timeout,
        retry: false,
        decode_json: [keys: :strings]
      ]
      |> Keyword.merge(opts)
      |> Keyword.merge(global_req_options())
      |> Keyword.merge(Keyword.get(ctx.opts, :req_options, []))

    Req.new(req_opts)
  end

  # App-env Req options merged into every request — used by the test env to
  # install a `Req.Test` plug globally. Empty in dev/prod.
  defp global_req_options do
    Application.get_env(:airo, __MODULE__, []) |> Keyword.get(:req_options, [])
  end

  ## SSE parsing

  # Append a raw chunk, emit any now-complete events, retain the partial tail.
  defp consume_sse(data, state) do
    {events, rest} = split_events(state.buffer <> data)

    acc =
      Enum.reduce(events, state.acc, fn raw, acc ->
        case event_data(raw) do
          {:ok, "[DONE]"} -> acc
          {:ok, json} -> reduce_json(json, acc, state.reducer)
          :none -> acc
        end
      end)

    %{state | buffer: rest, acc: acc}
  end

  # Split on blank-line event boundaries (LF or CRLF); the trailing element is
  # the incomplete event still being received.
  defp split_events(buffer) do
    case String.split(buffer, ~r/\r?\n\r?\n/) do
      [only] -> {[], only}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  # Concatenate the `data:` field(s) of one SSE event (SSE allows several).
  defp event_data(raw_event) do
    data =
      raw_event
      |> String.split(~r/\r?\n/)
      |> Enum.flat_map(fn
        "data:" <> rest -> [String.trim_leading(rest, " ")]
        _ -> []
      end)

    case data do
      [] -> :none
      lines -> {:ok, Enum.join(lines, "\n")}
    end
  end

  defp reduce_json(json, acc, reducer) do
    case Jason.decode(json) do
      {:ok, chunk} -> reducer.(chunk, acc)
      {:error, _} -> acc
    end
  end

  defp decode_error(""), do: %{}

  defp decode_error(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      {:error, _} -> raw
    end
  end

  defp load_credential(%Provider{credential: %Secret{} = secret}), do: secret
  defp load_credential(%Provider{credential_id: nil}), do: nil

  defp load_credential(%Provider{} = provider),
    do: provider |> Repo.preload(:credential) |> Map.get(:credential)

  defp normalize({:ok, %Req.Response{status: status, body: body, headers: headers}}) do
    {:ok, %{status: status, body: body, headers: headers}}
  end

  defp normalize({:error, exception}), do: {:error, exception}
end
