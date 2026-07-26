defmodule AiroWeb.UsageController do
  @moduledoc """
  Token and cost attribution for external consumers: `GET /v1/usage?since=`.

  Rolled up rather than streamed per call — a monitor wants totals per
  deployment, not every request. `since` partitions the record stream exactly:
  the response's `next_since` is the id of the newest record counted, so
  consecutive polls neither double-count nor drop a call at the boundary. Pass
  no `since` for all-time totals.

  `group_by` selects the attribution axis (`deployment` by default, or `model`,
  `alias`, `capability`, `client_key`).

  Requires a client key scoped `management`.
  """
  use AiroWeb, :controller

  alias Airo.Serving

  def index(conn, params) do
    json(
      conn,
      Serving.usage_rollup(
        since: Serving.parse_since(params["since"]),
        group_by: params["group_by"],
        limit: params["limit"]
      )
    )
  end
end
