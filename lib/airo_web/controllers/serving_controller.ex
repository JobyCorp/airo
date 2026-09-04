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

  Both require a client key scoped `management` (see
  `AiroWeb.Plugs.ClientKeyAuth`). `GET /v1/serving` is `ETag`-tagged: a poller
  that sends `If-None-Match` gets a `304` while topology is unchanged, so a tight
  poll interval costs almost nothing.
  """
  use AiroWeb, :controller

  alias Airo.Serving

  def index(conn, params) do
    snapshot = Serving.snapshot(inventory: truthy?(params["inventory"]))
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

  defp put_etag(conn, etag) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("cache-control", "no-cache")
  end

  # Fields that are purely a function of *now* rather than of state: they differ
  # on every call (`checked_at` even wobbles by milliseconds, being reconstructed
  # from a monotonic clock), so hashing them would make the ETag never match and
  # leave 304 as dead code. A client holding a 304'd body can recompute all of
  # them from its own clock, so dropping them costs nothing. Everything that
  # reflects real state — statuses, `stale`, latencies, last-seen — still counts.
  @clock_derived [:generated_at, :age_ms, :checked_at, :updated_at]

  defp etag_basis(%{} = map) when not is_struct(map) do
    map
    |> Map.drop(@clock_derived)
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
