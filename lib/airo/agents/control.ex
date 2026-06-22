defmodule Airo.Agents.Control do
  @moduledoc """
  HTTP client for an agent's **control API** (S17, see
  [DESIGN-agent-management.md](../../../DESIGN-agent-management.md) §4).

  The control plane is request/response over `agent.control_url`; slot *state*
  flows the other way, by channel push (`Airo.Agents.Ingest`). So `load/4` and
  `unload/3` only confirm the agent **accepted** the command — they return
  `:accepted`, not the loaded slot. Completion (`loading → up | failed`) arrives
  as a `slot` push and lands in `Airo.Agents.SlotState`.

  Auth reuses the shared bearer (`:airo, :agent_token`) — the same token the
  agent uses to join the channel. Calls are short-timeout: they are quick acks,
  not the (slow) model load itself, which the agent runs after replying.
  """

  alias Airo.Config.Agent
  alias Airo.Transport

  # Control calls are acks, not the load — keep the timeout tight.
  @receive_timeout 5_000

  @doc "Local models the host can serve, with provenance (`revision`)."
  @spec inventory(Agent.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def inventory(%Agent{} = agent, opts \\ []), do: get_list(agent, "/inventory", "models", opts)

  @doc "Re-scan the host's artifacts, then return the refreshed inventory."
  @spec refresh_inventory(Agent.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def refresh_inventory(%Agent{} = agent, opts \\ []) do
    with {:ok, %{status: s, body: body}} when s in 200..299 <-
           request(agent, :post, "/inventory/refresh", %{}, opts) do
      {:ok, list_field(body, "models")}
    else
      other -> error(other)
    end
  end

  @doc "Slots the agent reports right now (diagnostic; steady state arrives by push)."
  @spec slots(Agent.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def slots(%Agent{} = agent, opts \\ []), do: get_list(agent, "/slots", "slots", opts)

  @doc "Host GPU/VRAM snapshot (diagnostic; also pushed on the channel)."
  @spec gpu(Agent.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def gpu(%Agent{} = agent, opts \\ []) do
    with {:ok, %{status: s, body: body}} when s in 200..299 <-
           request(agent, :get, "/gpu", nil, opts) do
      {:ok, body}
    else
      other -> error(other)
    end
  end

  @doc """
  Load (or swap in) `model_id` on the slot at `port`. Uses the agent's default
  launch profile (per-load profiles are deferred — DESIGN §2). Returns
  `:accepted`; the slot transition arrives by push.
  """
  @spec load(Agent.t(), pos_integer(), String.t(), keyword()) :: :accepted | {:error, term()}
  def load(%Agent{} = agent, port, model_id, opts \\ [])
      when is_integer(port) and is_binary(model_id) do
    case request(agent, :post, "/load", %{model: model_id, slot: port}, opts) do
      {:ok, %{status: s}} when s in 200..299 -> :accepted
      {:ok, %{status: 404}} -> {:error, {:unknown_model, model_id}}
      {:ok, %{status: s, body: body}} -> {:error, {:rejected, s, reason(body)}}
      other -> error(other)
    end
  end

  @doc "Free the slot at `port` (unload its resident model). Returns `:accepted`."
  @spec unload(Agent.t(), pos_integer(), keyword()) :: :accepted | {:error, term()}
  def unload(%Agent{} = agent, port, opts \\ []) when is_integer(port) do
    case request(agent, :post, "/unload", %{slot: port}, opts) do
      {:ok, %{status: s}} when s in 200..299 -> :accepted
      {:ok, %{status: s, body: body}} -> {:error, {:rejected, s, reason(body)}}
      other -> error(other)
    end
  end

  # --- internals ---

  defp get_list(agent, path, field, opts) do
    with {:ok, %{status: s, body: body}} when s in 200..299 <-
           request(agent, :get, path, nil, opts) do
      {:ok, list_field(body, field)}
    else
      other -> error(other)
    end
  end

  defp request(%Agent{control_url: url}, _method, _path, _json, _opts)
       when not is_binary(url) or url == "",
       do: {:error, :no_control_url}

  defp request(%Agent{control_url: url}, method, path, json, opts) do
    req_opts =
      [
        method: method,
        url: Transport.full_url(url, path),
        finch: Airo.Finch,
        headers: auth_headers(),
        receive_timeout: @receive_timeout,
        retry: false,
        decode_json: [keys: :strings]
      ]
      |> maybe_put_json(json)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:ok, %{status: status, body: body, headers: headers}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp maybe_put_json(req_opts, nil), do: req_opts
  defp maybe_put_json(req_opts, json), do: Keyword.put(req_opts, :json, json)

  defp auth_headers do
    case Application.get_env(:airo, :agent_token) do
      token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
      _ -> []
    end
  end

  defp list_field(body, field) when is_map(body), do: Map.get(body, field, [])
  defp list_field(_body, _field), do: []

  defp reason(%{"error" => error}), do: error
  defp reason(body), do: body

  # A non-2xx with no more specific clause, or a transport error.
  defp error({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, reason(body)}}

  defp error({:error, _} = err), do: err
end
