defmodule Airo.Gateway.InFlight do
  @moduledoc """
  Live count of requests Airo is currently serving, per deployment (S28).

  Every inference request passes through `Airo.Gateway` in the process that
  owns the client connection, so that process is the natural unit of "one
  in-flight request". `track/2` registers the **calling process** under the
  deployment id in a duplicate-key `Registry`; `release/1` unregisters it;
  `count/1` and `snapshot/0` read.

  ## Why a Registry and not a counter

  A counter has to be decremented, and the process that would decrement it is
  exactly the one that dies when a client disconnects mid-stream, when an
  adapter raises, or when a 300 s chat upstream is killed. A leaked increment
  would then report a sequence as busy for as long as the node runs. Registry
  entries are owned by the registered process and vanish with it, so a crash
  or hangup releases the slot with no cleanup code on any path.

  ## What it does and does not count

  It counts requests **through Airo**: chat, stream, embeddings, rerank,
  speech, transcription, and realtime WebSocket sessions for their whole life.
  It cannot see a caller that hits an engine's port directly. For that, ask
  the engine — `Airo.Serving.activity/1` with `engine: true` scrapes vLLM's own
  `num_requests_running` and reports whichever count is larger.

  A failover is one request: the first attempt is released **before** the next
  is tracked, so a fallback never counts twice.
  """

  @registry __MODULE__

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry, partitions: 1)
  end

  @doc """
  Register the calling process as one in-flight request on `deployment_id`.
  `meta` is kept with the entry (`capability`, `client_key_id`) and stamped
  with a monotonic `started_at`. A `nil` id is a no-op, so callers with a
  deployment that never persisted (tests, synthetic targets) need no guard.
  """
  @spec track(integer() | nil, map()) :: :ok
  def track(deployment_id, meta \\ %{})

  def track(deployment_id, meta) when is_integer(deployment_id) do
    meta = Map.put_new(meta, :started_at, System.monotonic_time(:millisecond))
    {:ok, _owner} = Registry.register(@registry, deployment_id, meta)
    :ok
  end

  def track(_deployment_id, _meta), do: :ok

  @doc "Release every entry the calling process holds on `deployment_id`."
  @spec release(integer() | nil) :: :ok
  def release(deployment_id) when is_integer(deployment_id) do
    Registry.unregister(@registry, deployment_id)
  end

  def release(_deployment_id), do: :ok

  @doc "Requests currently in flight on `deployment_id`, across every process."
  @spec count(integer() | nil) :: non_neg_integer()
  def count(deployment_id) when is_integer(deployment_id) do
    Registry.count_match(@registry, deployment_id, :_)
  end

  def count(_deployment_id), do: 0

  @doc """
  In-flight counts for every deployment with at least one, as
  `%{deployment_id => count}`. Deployments with nothing in flight are absent
  rather than zero, so a reader folds with a default.
  """
  @spec snapshot() :: %{integer() => pos_integer()}
  def snapshot do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.frequencies()
  end
end
