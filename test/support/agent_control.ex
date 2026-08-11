defmodule Airo.Test.AgentControl do
  @moduledoc """
  Helpers for the online-only half of `/admin/agents/:id` (S23).

  That surface — the loadable-models table, the config modal, Configure /
  Unload / Refresh / Resync — renders only when a host is online, and reaching
  it from a test means picking two locks at once:

    * **Presence.** `AiroWeb.Admin.AgentLive.online?/1` is
      `Presence.list("agent:<host_id>") != %{}`. Nothing else makes a host look
      up. `mark_online/1`.

    * **The control API.** Once the page believes a host is online it fetches
      that host's inventory over HTTP. Without a stub the request goes to a
      `control_url` that doesn't resolve and the page renders its error branch
      instead of the one under test. `stub_control/1`.

  ## Why these tests are `async: false`

  `Req.Test` stubs are owned by the process that installs them. The inventory
  fetch happens *inside the LiveView process during mount*, before the test has
  a pid to grant an allowance to, so ownership can't be delegated in time. The
  stub therefore has to be global, which rules out concurrent tests in the same
  module. Keep them in their own file so the rest of the suite stays `async`.
  """

  alias AiroWeb.Presence

  @doc """
  Make `host_id` look connected for the duration of the test.

  Tracks the calling process on the agent's Presence topic — the same topic
  `AiroWeb.AgentChannel` uses. Presence monitors the tracking pid, so the test
  process exiting untracks it; no explicit cleanup. Use a unique `host_id` per
  test anyway: the tracker is shared, and a leak shows up as an order-dependent
  failure somewhere else.
  """
  def mark_online(host_id) do
    {:ok, _ref} = Presence.track(self(), "agent:#{host_id}", host_id, %{online_at: 0})
    :ok
  end

  @doc """
  Answer this test's `Airo.Agents.Control` calls with `fun`.

  Installs the `Req.Test` plug on `Control` **for this test only** and takes it
  back off on exit.

  Doing this globally in `config/test.exs` was the first attempt and it was
  wrong: routing every `Control` call through `Req.Test` makes an un-stubbed
  call *raise*, where before it failed like an unreachable host. Several
  existing tests depend on exactly that failure — `Ingest.inventory_index/1`
  degrades to identity-only when the control API can't be reached (S19), and
  they were asserting the degraded path. Opting in per test leaves every other
  test seeing the real, refused connection it always saw.

  Shared rather than process-owned because the request happens in the LiveView
  process — see the module doc. Safe here only because these tests are
  `async: false`, so nothing else is running to see the global app env.

      stub_control(fn conn -> Req.Test.json(conn, %{"models" => []}) end)
  """
  def stub_control(fun) when is_function(fun, 1) do
    previous = Application.get_env(:airo, Airo.Agents.Control)

    Application.put_env(:airo, Airo.Agents.Control,
      req_options: [plug: {Req.Test, Airo.Agents.Control}]
    )

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:airo, Airo.Agents.Control, previous),
        else: Application.delete_env(:airo, Airo.Agents.Control)
    end)

    Req.Test.set_req_test_to_shared()
    Req.Test.stub(Airo.Agents.Control, fun)
  end

  @doc """
  Answer `GET /inventory` with `models` and 404 anything else.

  The shape mirrors what `airo_agent` returns: `id` is the real model id and
  `size_bytes` feeds `Airo.Agents.Capacity`, so a model with no size lands on
  the `fits?: :unknown` path rather than being treated as zero-cost.
  """
  def stub_inventory(models) when is_list(models) do
    stub_control(fn conn ->
      case conn.request_path do
        "/inventory" -> Req.Test.json(conn, %{"models" => models})
        _ -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not stubbed"})
      end
    end)
  end

  @doc "An `/inventory` model entry with sensible defaults."
  def model(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => id,
        "engine" => "llama_cpp",
        "size_bytes" => 4_000_000_000,
        "ctx_max" => 32_768
      },
      attrs
    )
  end
end
