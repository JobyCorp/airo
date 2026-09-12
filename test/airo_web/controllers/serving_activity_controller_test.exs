defmodule AiroWeb.ServingActivityControllerTest do
  # `GET /v1/serving/activity` (S28), the topology ETag repair, and the four
  # activity gauges on `/metrics`. Slot state, health and the in-flight
  # Registry are shared across the node, so not async.
  use AiroWeb.ConnCase, async: false

  alias Airo.Agents.SlotState
  alias Airo.Config

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.health_table())
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
    :ets.delete_all_objects(Airo.Runtime.Store.hosts_table())
    :ok
  end

  defp mint(scopes) do
    {:ok, key} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: ["*"],
        scopes: scopes
      })

    key.key
  end

  defp authed(conn, key), do: put_req_header(conn, "authorization", "Bearer " <> key)
  defp management(conn), do: authed(conn, mint([:management]))

  defp provider(attrs) do
    {:ok, provider} =
      Config.create_provider(
        Map.merge(
          %{
            name: "p-#{System.unique_integer([:positive])}",
            adapter_type: :openai,
            base_url: "http://p:8080/v1",
            auth_kind: :none
          },
          attrs
        )
      )

    provider
  end

  defp deployment(provider, attrs) do
    {:ok, deployment} =
      Config.create_deployment(
        Map.merge(
          %{
            provider_id: provider.id,
            model_name: "m-#{System.unique_integer([:positive])}",
            capabilities: [:chat]
          },
          attrs
        )
      )

    deployment
  end

  describe "GET /v1/serving/activity (S28)" do
    alias Airo.Gateway.InFlight

    defp managed_slot do
      {:ok, agent} =
        Config.create_agent(%{
          host_id: "host-#{System.unique_integer([:positive])}",
          control_url: "http://host:4400",
          gpu: %{"available" => true, "vram_total_mb" => 24_564, "vram_used_mb" => 18_201}
        })

      slot = provider(%{agent_id: agent.id, name: "#{agent.host_id}:8080"})

      {:ok, model} =
        Config.create_model(%{
          upstream_model_id: "u-#{System.unique_integer([:positive])}",
          display_name: "m",
          status: :evaluating
        })

      deployment = deployment(slot, %{model_name: "m", model_id: model.id})

      SlotState.put(slot.id, %{
        resident_model: "m",
        status: "up",
        model_id: model.id,
        parallel: 4
      })

      %{agent: agent, slot: slot, deployment: deployment}
    end

    test "requires a management key", %{conn: conn} do
      assert conn
             |> authed(mint([:inference]))
             |> get(~p"/v1/serving/activity")
             |> json_response(403)
    end

    test "reports loaded, max, in-flight and available per deployment, uncached", %{conn: conn} do
      %{deployment: d, agent: agent} = managed_slot()
      InFlight.track(d.id)

      response = conn |> management() |> get(~p"/v1/serving/activity")
      body = json_response(response, 200)

      assert get_resp_header(response, "etag") == []
      assert get_resp_header(response, "cache-control") == ["no-store"]

      assert %{
               "loaded" => true,
               "slot_status" => "up",
               "max_concurrency" => 4,
               "in_flight" => 1,
               "available_concurrency" => 3,
               "source" => "gateway",
               "engine" => nil,
               "host_id" => host_id
             } = Enum.find(body["deployments"], &(&1["id"] == d.id))

      assert host_id == agent.host_id
      InFlight.release(d.id)
    end

    test "a heartbeat and a telemetry wobble do not change the topology ETag", %{conn: _conn} do
      %{agent: agent} = managed_slot()
      key = mint([:management])

      [before] = build_conn() |> authed(key) |> get(~p"/v1/serving") |> get_resp_header("etag")

      {:ok, _} =
        Config.update_agent(agent, %{
          last_seen_at: DateTime.utc_now() |> DateTime.add(10, :second),
          gpu: %{
            "available" => true,
            "vram_total_mb" => 24_564,
            "vram_used_mb" => 18_190,
            "power_draw_w" => 9.71
          }
        })

      [after_wobble] =
        build_conn() |> authed(key) |> get(~p"/v1/serving") |> get_resp_header("etag")

      assert after_wobble == before
    end

    test "a slot going down still changes the topology ETag", %{conn: _conn} do
      %{slot: slot, deployment: _d} = managed_slot()
      key = mint([:management])

      [before] = build_conn() |> authed(key) |> get(~p"/v1/serving") |> get_resp_header("etag")
      SlotState.put(slot.id, %{resident_model: "m", status: "down", parallel: 4})
      [changed] = build_conn() |> authed(key) |> get(~p"/v1/serving") |> get_resp_header("etag")

      refute changed == before
    end

    test "/metrics carries the loaded and concurrency gauges", %{conn: conn} do
      %{deployment: d, slot: slot} = managed_slot()
      InFlight.track(d.id)

      body = conn |> management() |> get("/metrics") |> response(200)

      assert body =~ ~s(airo_deployment_loaded{)
      assert body =~ ~s(provider="#{slot.name}",model_name="m",deployment_id="#{d.id}"} 1)
      assert body =~ ~s(airo_deployment_max_concurrency{)
      assert body =~ ~s(airo_deployment_in_flight{)
      assert body =~ ~s(airo_deployment_available_concurrency{)
      InFlight.release(d.id)
    end
  end
end
