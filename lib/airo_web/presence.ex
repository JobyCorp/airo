defmodule AiroWeb.Presence do
  @moduledoc """
  Tracks connected `airo_agent` hosts (decision #3). Presence here is the
  poll-free liveness signal: while a host's agent is connected it appears in the
  set; a disconnect is the host going away. The functional mark-down on
  disconnect lives in `AiroWeb.AgentChannel.terminate/2`; this powers visibility
  (which hosts are online) for the UI.
  """
  use Phoenix.Presence, otp_app: :airo, pubsub_server: Airo.PubSub
end
