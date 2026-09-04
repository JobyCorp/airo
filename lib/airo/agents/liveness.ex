defmodule Airo.Agents.Liveness do
  @moduledoc """
  Host liveness beyond Presence (S25, DESIGN-agent-lifecycle-and-roles.md §2).

  Presence answers "is the socket open". It cannot answer "is the agent behind
  it still talking" — a hung agent keeps its TCP connection and simply stops
  sending the 10 s `register` heartbeat, and until this module existed such a
  host looked healthy forever at the host level.

  Two signals, evaluated on every sweep for every known host:

    * **stale** — present in Presence *and* `agents.last_seen_at` older than
      `agent_stale_after_ms` (`/admin/settings`). Entering stale records a
      `:stale` transition and marks the host's deployments `:unknown`
      (`source: :agent, reason: "agent_stale"`) so routing preference follows.
      The next register clears it with a `:recovered` transition — recovery is
      immediate, matching S24's "hysteresis down, none up".

    * **presence lost** — absent from Presence but still holding `SlotState`,
      i.e. the channel died without `terminate/2` running. Treated as the
      disconnect it is: `:disconnected` is recorded and `Ingest.host_down/1`
      does what a clean terminate would have. After an Airo restart the ETS is
      empty, so this never fires on boot.

  The stale flag is runtime state in the `:airo_hosts` ETS table
  (`Airo.Runtime.Store`) — it must reset with the node, not persist. The
  GenServer only schedules; `sweep/0` is a plain function so tests drive it
  directly.
  """
  use GenServer

  require Logger

  alias Airo.Agents.{Ingest, Lifecycle, SlotState}
  alias Airo.{Config, Health, Repo, Runtime.Store}
  alias AiroWeb.Presence

  @default_interval_ms 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if enabled?(), do: schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  @doc "Whether `host_id`'s agent currently holds an open channel (Presence)."
  @spec online?(String.t()) :: boolean()
  def online?(host_id), do: Presence.list("agent:#{host_id}") != %{}

  @doc "Whether `host_id` is currently flagged stale."
  @spec stale?(String.t()) :: boolean()
  def stale?(host_id), do: :ets.member(Store.hosts_table(), {:stale, host_id})

  @doc "Every host currently flagged stale."
  @spec stale_hosts() :: [String.t()]
  def stale_hosts do
    :ets.select(Store.hosts_table(), [{{{:stale, :"$1"}, :_}, [], [:"$1"]}])
  end

  @doc """
  A register arrived for `host_id`. Clears the stale flag if set, recording
  `:recovered` with how long the silence lasted. Cheap when the host is not
  stale — one ETS lookup — so `Ingest.register/2` calls it on every heartbeat.
  """
  @spec registered(String.t()) :: :ok
  def registered(host_id) do
    case :ets.lookup(Store.hosts_table(), {:stale, host_id}) do
      [{_key, %{since: since, silent_ms: silent_ms}}] ->
        :ets.delete(Store.hosts_table(), {:stale, host_id})
        stale_for = System.monotonic_time(:millisecond) - since

        Lifecycle.transition(host_id, :recovered,
          reason: "register after #{stale_for + silent_ms}ms",
          meta: %{silent_ms: silent_ms, stale_ms: stale_for},
          measurements: %{silent_ms: silent_ms + stale_for}
        )

        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Evaluate every known host once. Returns `%{stale: [...], lost: [...]}` — the
  hosts that *entered* stale and the hosts whose presence was found lost on
  this pass — mostly for tests and `iex`.
  """
  @spec sweep() :: %{stale: [String.t()], lost: [String.t()]}
  def sweep do
    threshold_ms = Config.agent_stale_after_ms()
    now = DateTime.utc_now()

    Config.list_agents()
    |> Repo.preload(providers: :deployments)
    |> Enum.reduce(%{stale: [], lost: []}, fn agent, acc ->
      case evaluate(agent, now, threshold_ms) do
        :stale -> %{acc | stale: [agent.host_id | acc.stale]}
        :lost -> %{acc | lost: [agent.host_id | acc.lost]}
        :ok -> acc
      end
    end)
  end

  defp evaluate(agent, now, threshold_ms) do
    present? = Presence.list("agent:#{agent.host_id}") != %{}
    silent_ms = silent_ms(agent.last_seen_at, now)

    cond do
      present? and silent_ms != nil and silent_ms > threshold_ms and not stale?(agent.host_id) ->
        mark_stale(agent, silent_ms)
        :stale

      not present? and holds_slot_state?(agent) ->
        # Disconnect supersedes stale: the flag would otherwise survive until the
        # host's next register and then report a recovery that never happened.
        :ets.delete(Store.hosts_table(), {:stale, agent.host_id})

        Lifecycle.transition(agent.host_id, :disconnected,
          agent: agent,
          reason: "presence_lost",
          meta: %{detected_by: "liveness_sweep"}
        )

        Ingest.host_down(agent.host_id)
        :lost

      not present? and stale?(agent.host_id) ->
        :ets.delete(Store.hosts_table(), {:stale, agent.host_id})
        :ok

      true ->
        :ok
    end
  end

  defp mark_stale(agent, silent_ms) do
    :ets.insert(
      Store.hosts_table(),
      {{:stale, agent.host_id},
       %{since: System.monotonic_time(:millisecond), silent_ms: silent_ms}}
    )

    Lifecycle.transition(agent.host_id, :stale,
      agent: agent,
      reason: "no register for #{silent_ms}ms",
      meta: %{silent_ms: silent_ms},
      measurements: %{silent_ms: silent_ms}
    )

    # Preference, not a gate: `:unknown` demotes the host's deployments in
    # routing order without removing them, and the next register re-marks them
    # from the slot pushes it carries.
    for provider <- agent.providers, deployment <- provider.deployments do
      Health.mark_deployment(deployment, provider, :unknown,
        source: :agent,
        reason: "agent_stale"
      )
    end
  end

  defp holds_slot_state?(agent), do: Enum.any?(agent.providers, &SlotState.get(&1.id))

  defp silent_ms(nil, _now), do: nil
  defp silent_ms(%DateTime{} = last_seen, now), do: DateTime.diff(now, last_seen, :millisecond)

  defp schedule, do: Process.send_after(self(), :sweep, interval_ms())

  defp enabled?, do: Keyword.get(config(), :enabled, true)
  defp interval_ms, do: Keyword.get(config(), :interval_ms, @default_interval_ms)
  defp config, do: Application.get_env(:airo, __MODULE__, [])
end
