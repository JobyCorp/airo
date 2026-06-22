defmodule AiroWeb.AgentSocket do
  @moduledoc """
  WebSocket endpoint for `airo_agent` host-side control agents (decision #3).

  Inverted direction: the agent is the *client* (a `slipstream` connection); Airo
  is the server. Each serving host opens one connection and joins `agent:<host_id>`.
  Auth is a shared bearer token (`:airo, :agent_token`); when none is configured
  the socket accepts any connection (loopback/dev — auth is a deferred sprint).
  """
  use Phoenix.Socket

  channel "agent:*", AiroWeb.AgentChannel

  @impl true
  def connect(params, socket, _connect_info) do
    with host_id when is_binary(host_id) and host_id != "" <- params["host_id"],
         true <- valid_token?(params["token"]) do
      {:ok, assign(socket, :host_id, host_id)}
    else
      _ -> :error
    end
  end

  # Per-host id lets Airo force-disconnect a host (`Endpoint.broadcast/3`).
  @impl true
  def id(socket), do: "agent_socket:#{socket.assigns.host_id}"

  defp valid_token?(token) do
    case Application.get_env(:airo, :agent_token) do
      configured when is_binary(configured) and configured != "" ->
        is_binary(token) and Plug.Crypto.secure_compare(token, configured)

      _ ->
        true
    end
  end
end
