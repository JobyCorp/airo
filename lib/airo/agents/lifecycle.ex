defmodule Airo.Agents.Lifecycle do
  @moduledoc """
  The one place a host lifecycle transition is recorded (S25,
  DESIGN-agent-lifecycle-and-roles.md §2).

  `transition/3` does four things, in order, for every host-level change:

    1. inserts a `HostEvent` (incident history — keeps everything);
    2. mirrors the operator-relevant kinds into `log_events` via
       `Airo.Logs.record/1` (what `/admin/logs` shows — connect, disconnect,
       stale, recovered; a version bump is not an incident);
    3. broadcasts `{:agent_event, %{host_id, kind}}` on the fleet topic
       `"agents"`, so roster-level views update without subscribing per host;
    4. executes a `:telemetry` event under `[:airo, :agent, _]`.

  Nothing else writes `host_events`, which is what keeps the four consumers in
  agreement. Recording must never fail an ingest: a bad insert is logged and
  swallowed, and the broadcast/telemetry still fire so the UI reflects the
  transition even when the history row was lost.

  Heartbeats are not transitions. `register` arrives every 10 s per host; the
  callers only reach here when something actually changed.
  """
  require Logger

  import Ecto.Query, warn: false

  alias Airo.{Config, Logs, Repo}
  alias Airo.Agents.HostEvent

  @pubsub Airo.PubSub
  @topic "agents"

  # Kinds an operator should see in the operational log, with their level.
  @mirrored %{connected: :info, disconnected: :warning, stale: :warning, recovered: :info}

  # Telemetry event name per kind — the names in the design note's catalogue.
  @telemetry %{
    connected: :join,
    disconnected: :leave,
    stale: :stale,
    recovered: :recovered,
    version_changed: :changed,
    control_url_changed: :changed,
    role_changed: :changed
  }

  @doc "The fleet-wide PubSub topic. Message: `{:agent_event, %{host_id: id, kind: kind}}`."
  def topic, do: @topic

  @doc "Subscribe the caller to every host's lifecycle transitions."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc """
  Record that `host_id` made a `kind` transition.

  Options:

    * `:reason` — short text (clipped to 255), e.g. `"agent_disconnected"`.
    * `:meta` — kind-specific map stored on the row and passed to telemetry.
    * `:agent` — the `%Agent{}` if the caller already holds it (saves a query);
      otherwise looked up by `host_id`, and may legitimately be `nil` for a
      host that connected before its first register.
    * `:measurements` — extra telemetry measurements (e.g. `silent_ms`).

  Returns `{:ok, %HostEvent{}}` or `{:error, term}`; callers ignore it.
  """
  @spec transition(String.t(), atom(), keyword()) :: {:ok, HostEvent.t()} | {:error, term()}
  def transition(host_id, kind, opts \\ [])
      when is_binary(host_id) and
             kind in [
               :connected,
               :disconnected,
               :stale,
               :recovered,
               :version_changed,
               :control_url_changed,
               :role_changed
             ] do
    agent = Keyword.get_lazy(opts, :agent, fn -> Config.get_agent_by_host_id(host_id) end)
    meta = stringify(opts[:meta] || %{})
    reason = clip(opts[:reason])

    attrs = %{
      agent_id: agent && agent.id,
      host_id: host_id,
      kind: kind,
      reason: reason,
      meta: meta
    }

    result = insert(attrs)

    log(host_id, kind, reason, meta)
    mirror(attrs)
    broadcast(host_id, kind)
    execute(host_id, kind, meta, opts[:measurements] || %{})

    result
  end

  @doc "Most recent events for one host, newest first."
  @spec recent(String.t(), pos_integer()) :: [HostEvent.t()]
  def recent(host_id, limit \\ 50) when is_binary(host_id) do
    HostEvent
    |> where([e], e.host_id == ^host_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp insert(attrs) do
    %HostEvent{} |> HostEvent.changeset(attrs) |> Repo.insert()
  rescue
    error ->
      Logger.warning("host event insert failed for #{attrs.host_id}: #{Exception.message(error)}")
      {:error, error}
  end

  # One structured line per transition, so a plain log tail answers "what did
  # this host do" without the database. Metadata keys are `host_id` and `kind`.
  defp log(host_id, kind, reason, meta) do
    level = Map.get(@mirrored, kind, :info)
    suffix = if reason, do: " (#{reason})", else: ""

    Logger.log(level, "agent #{host_id} #{kind}#{suffix}",
      host_id: host_id,
      kind: kind,
      meta: meta
    )
  end

  defp mirror(%{kind: kind} = attrs) do
    case Map.fetch(@mirrored, kind) do
      {:ok, level} ->
        Logs.record(%{
          kind: :host,
          level: level,
          summary: summary(attrs),
          data:
            Map.merge(attrs.meta, %{
              "host_id" => attrs.host_id,
              "kind" => to_string(kind),
              "reason" => attrs.reason
            })
        })

      :error ->
        :ok
    end
  end

  defp summary(%{host_id: host_id, kind: kind, reason: nil}),
    do: "host #{kind} host_id=#{host_id}"

  defp summary(%{host_id: host_id, kind: kind, reason: reason}),
    do: "host #{kind} host_id=#{host_id} reason=#{reason}"

  defp broadcast(host_id, kind) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:agent_event, %{host_id: host_id, kind: kind}})
  end

  defp execute(host_id, kind, meta, measurements) do
    :telemetry.execute(
      [:airo, :agent, Map.fetch!(@telemetry, kind)],
      Map.merge(%{count: 1}, measurements),
      Map.merge(%{host_id: host_id, kind: kind}, atomize(meta))
    )
  end

  # `meta` is stored as JSON, so keys are normalised to strings on the row…
  defp stringify(meta) when is_map(meta), do: Map.new(meta, fn {k, v} -> {to_string(k), v} end)

  # …and handed to telemetry as atoms, which is what handlers pattern-match on.
  defp atomize(meta) when is_map(meta),
    do: Map.new(meta, fn {k, v} -> {String.to_atom(to_string(k)), v} end)

  defp clip(nil), do: nil
  defp clip(reason), do: reason |> to_string() |> String.slice(0, 255)
end
