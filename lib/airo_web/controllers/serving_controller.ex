defmodule AiroWeb.ServingController do
  @moduledoc """
  Serving topology for external consumers (orchester and anything else that
  needs to bind a served model back to a host).

    - `GET /v1/serving` — hosts, slots, resident models, external providers and
      aliases, as one snapshot.
    - `GET /v1/serving/health?since=` — health *transitions*, so a consumer can
      record flaps rather than sampling current state and missing what happened
      between polls.
    - `GET /v1/serving/hosts?since=` — host *lifecycle* events (S25): connect,
      disconnect, stale, recovered, identity changes. Same cursor contract.
    - `GET /v1/serving/activity` — the live view for an orchestrator (S28):
      per deployment, `loaded`, `max_concurrency`, `in_flight` and
      `available_concurrency`. Changes on every request start and end, so it
      carries no `ETag` and is sent `no-store`; `?engine=1` adds each vLLM
      engine's own running/waiting counters.

  All require a client key scoped `management` (see
  `AiroWeb.Plugs.ClientKeyAuth`). `GET /v1/serving` is `ETag`-tagged: a poller
  that sends `If-None-Match` gets a `304` while topology is unchanged, so a tight
  poll interval costs almost nothing. Host heartbeat time and GPU telemetry are
  left out of the tag on purpose — they move every few seconds and would
  otherwise keep the `304` from ever firing (which is what happened until S28;
  read them from `/metrics` if you want the raw readings).

  ## Query parameters on `GET /v1/serving`

    - `inventory=1` — also report what each host holds on disk.
    - `speculative=1` — also scrape each vLLM slot's own `/metrics` and report
      a derived speculative-decode block per deployment. Both cost one outbound
      call per host (or per vLLM slot), so both are off by default.

  `speculative=1` defeats the `ETag`: the counters climb on every request the
  engine serves, so the snapshot almost always differs and a `304` almost never
  fires. Poll topology without it, and ask for it only when you want the
  numbers. And read `Airo.Speculative` before using them — they are cumulative
  since engine start, not per request.
  """
  use AiroWeb, :controller

  alias Airo.Serving

  def index(conn, params) do
    snapshot =
      Serving.snapshot(
        inventory: truthy?(params["inventory"]),
        speculative: truthy?(params["speculative"])
      )

    etag = etag(etag_basis(snapshot))

    if etag in get_req_header(conn, "if-none-match") do
      conn |> put_etag(etag) |> send_resp(304, "")
    else
      conn |> put_etag(etag) |> json(snapshot)
    end
  end

  def health(conn, params) do
    json(
      conn,
      Serving.health_transitions(
        since: Serving.parse_since(params["since"]),
        limit: params["limit"]
      )
    )
  end

  def hosts(conn, params) do
    json(
      conn,
      Serving.host_transitions(
        since: Serving.parse_since(params["since"]),
        limit: params["limit"]
      )
    )
  end

  # Un-cacheable by construction: `in_flight` moves with every request, so an
  # `ETag` here would never match and a cache would only ever serve a stale
  # count to something about to dispatch on it.
  def activity(conn, params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(Serving.activity(engine: truthy?(params["engine"])))
  end

  defp put_etag(conn, etag) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("cache-control", "no-cache")
  end

  # Fields that move without topology moving. The clock-derived ones
  # (`checked_at` even wobbles by milliseconds, being reconstructed from a
  # monotonic clock) a client can recompute from its own clock. `last_seen_at`
  # advances on every heartbeat and the `gpu` map — power draw, memory — on
  # every 5 s poll; with either in the hash the ETag changed on every call and
  # `304` was dead code (verified 2026-09-12, S28). Everything that reflects
  # real state — statuses, `online`/`stale`, latencies, `loaded` — still counts.
  @volatile [:generated_at, :age_ms, :checked_at, :updated_at, :last_seen_at, :gpu]

  defp etag_basis(%{} = map) when not is_struct(map) do
    map
    |> Map.drop(@volatile)
    |> Map.new(fn {k, v} -> {k, etag_basis(v)} end)
  end

  defp etag_basis(list) when is_list(list), do: Enum.map(list, &etag_basis/1)
  defp etag_basis(other), do: other

  # `:deterministic` is required: without it map key order in the encoding is
  # unspecified, so the same topology could hash differently between calls.
  defp etag(term) do
    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    ~s("#{digest}")
  end

  defp truthy?(value), do: value in ["1", "true", "yes"]
end
