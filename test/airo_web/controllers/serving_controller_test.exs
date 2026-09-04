defmodule AiroWeb.ServingControllerTest do
  use AiroWeb.ConnCase, async: false

  alias Airo.Agents.SlotState
  alias Airo.{Config, Health, Usage}

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.health_table())
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
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

  defp provider(attrs \\ %{}) do
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

  defp deployment(provider, attrs \\ %{}) do
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

  describe "authorization" do
    test "rejects a request with no client key", %{conn: conn} do
      assert conn |> get(~p"/v1/serving") |> json_response(401)
    end

    test "rejects an inference-scoped key with 403, not 401", %{conn: conn} do
      conn = authed(conn, mint([:inference]))

      # The credential is valid; the surface is not granted to it.
      assert %{"error" => %{"code" => "insufficient_scope"}} =
               conn |> get(~p"/v1/serving") |> json_response(403)
    end

    test "rejects a disabled management key", %{conn: conn} do
      raw = mint([:management])
      key = Config.list_client_keys() |> List.last()
      {:ok, _} = Config.update_client_key(key, %{enabled: false})

      assert conn |> authed(raw) |> get(~p"/v1/serving") |> json_response(401)
    end

    test "guards every management endpoint", %{conn: conn} do
      key = mint([:inference])

      for path <- [~p"/v1/serving", ~p"/v1/serving/health", ~p"/v1/usage", "/metrics"] do
        assert conn |> authed(key) |> get(path) |> Map.fetch!(:status) == 403
      end
    end

    test "a management key does not gain the inference surface", %{conn: conn} do
      assert conn |> management() |> get(~p"/v1/models") |> json_response(403)
    end
  end

  describe "GET /v1/serving" do
    test "returns hosts, slots, resident models, providers and aliases", %{conn: conn} do
      {:ok, agent} =
        Config.create_agent(%{
          host_id: "jobycorp",
          control_url: "http://jobycorp:4400",
          version: "0.3.1",
          gpu: %{"available" => true, "vram_total_mb" => 24_564, "vram_used_mb" => 18_201}
        })

      slot = provider(%{agent_id: agent.id, name: "jobycorp:8080"})
      served = deployment(slot, %{model_name: "Qwen3.6-35B", capabilities: [:chat, :vision]})
      Health.mark(served.id, :up, 12)

      SlotState.put(slot.id, %{
        resident_model: "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf",
        status: "up",
        ctx: 32_768,
        ctx_total: 131_072
      })

      body = conn |> management() |> get(~p"/v1/serving") |> json_response(200)

      assert body["generated_at"]
      assert body["staleness_ms"] == Health.staleness_ms()

      host = Enum.find(body["hosts"], &(&1["host_id"] == "jobycorp"))
      assert host["control_url"] == "http://jobycorp:4400"
      assert host["agent_version"] == "0.3.1"
      assert host["gpu"]["vram_free_mb"] == 6363.0

      assert [slot_json] = host["slots"]
      assert slot_json["provider"] == "jobycorp:8080"
      assert slot_json["base_url"] == "http://p:8080/v1"
      assert slot_json["adapter_type"] == "openai"
      assert slot_json["resident"]["model"] == "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
      assert slot_json["resident"]["ctx"] == 32_768
      assert slot_json["resident"]["ctx_total"] == 131_072

      assert [deployment_json] = slot_json["deployments"]
      assert deployment_json["model_name"] == "Qwen3.6-35B"
      assert deployment_json["capabilities"] == ["chat", "vision"]
      assert deployment_json["health"]["status"] == "up"
      assert deployment_json["routable"] == true
    end

    test "separates agent-managed slots from external providers", %{conn: conn} do
      {:ok, agent} = Config.create_agent(%{host_id: "boxy", control_url: "http://boxy:4400"})
      provider(%{agent_id: agent.id, name: "boxy:8080"})
      external = provider(%{name: "ollama-nas", adapter_type: :ollama})
      deployment(external)

      body = conn |> management() |> get(~p"/v1/serving") |> json_response(200)

      assert Enum.find(body["hosts"], &(&1["host_id"] == "boxy"))
      assert entry = Enum.find(body["external_providers"], &(&1["provider"] == "ollama-nas"))
      assert entry["adapter_type"] == "ollama"
      assert entry["health"]["status"]
    end

    test "does not fetch host inventory unless asked", %{conn: conn} do
      {:ok, agent} =
        Config.create_agent(%{host_id: "offline", control_url: "http://127.0.0.1:1/nope"})

      provider(%{agent_id: agent.id, name: "offline:8080"})

      body = conn |> management() |> get(~p"/v1/serving") |> json_response(200)

      assert Enum.find(body["hosts"], &(&1["host_id"] == "offline"))["inventory"] == nil
    end

    test "an unreachable host degrades its inventory to null instead of failing", %{conn: conn} do
      {:ok, agent} =
        Config.create_agent(%{host_id: "offline", control_url: "http://127.0.0.1:1/nope"})

      provider(%{agent_id: agent.id, name: "offline:8080"})

      body =
        conn |> management() |> get(~p"/v1/serving?inventory=true") |> json_response(200)

      assert Enum.find(body["hosts"], &(&1["host_id"] == "offline"))["inventory"] == nil
    end

    test "serves 304 to a conditional request while topology is unchanged", _context do
      deployment(provider())
      key = mint([:management])

      first = build_conn() |> authed(key) |> get(~p"/v1/serving")
      assert first.status == 200
      assert [etag] = get_resp_header(first, "etag")

      cached =
        build_conn()
        |> authed(key)
        |> put_req_header("if-none-match", etag)
        |> get(~p"/v1/serving")

      assert cached.status == 304
      assert cached.resp_body == ""
    end

    test "changes the etag when a deployment's health changes", _context do
      served = deployment(provider())
      Health.mark(served.id, :up, 5)
      key = mint([:management])

      [before] = build_conn() |> authed(key) |> get(~p"/v1/serving") |> get_resp_header("etag")

      Health.mark(served.id, :down)

      [changed] = build_conn() |> authed(key) |> get(~p"/v1/serving") |> get_resp_header("etag")

      refute before == changed
    end
  end

  describe "GET /v1/serving/health" do
    test "returns transitions with previous state and a cursor", %{conn: conn} do
      p = provider()
      d = deployment(p)

      for status <- [:up, :down, :up] do
        {:ok, _} =
          Health.record_event(%{
            deployment_id: d.id,
            provider_id: p.id,
            status: status,
            source: :probe
          })
      end

      body = conn |> management() |> get(~p"/v1/serving/health") |> json_response(200)

      events = Enum.filter(body["events"], &(&1["deployment_id"] == d.id))
      assert length(events) == 3
      assert Enum.at(events, 1)["previous_status"] == "up"
      assert Enum.at(events, 1)["status"] == "down"
      assert Enum.at(events, 1)["changed"] == true
      assert Enum.at(events, 1)["provider"] == p.name
      assert body["next_since"]
      assert body["has_more"] == false
    end

    test "honours the since cursor and limit", %{conn: conn} do
      p = provider()
      d = deployment(p)

      for status <- [:up, :down, :up, :down] do
        {:ok, _} =
          Health.record_event(%{
            deployment_id: d.id,
            provider_id: p.id,
            status: status,
            source: :probe
          })
      end

      page = conn |> management() |> get(~p"/v1/serving/health?limit=2") |> json_response(200)
      assert length(page["events"]) == 2
      assert page["has_more"] == true

      next =
        build_conn()
        |> management()
        |> get(~p"/v1/serving/health?since=#{page["next_since"]}")
        |> json_response(200)

      assert Enum.all?(next["events"], &(&1["id"] > page["next_since"]))
    end

    test "accepts an ISO 8601 timestamp as the cursor", %{conn: conn} do
      p = provider()
      d = deployment(p)

      {:ok, _} =
        Health.record_event(%{
          deployment_id: d.id,
          provider_id: p.id,
          status: :up,
          source: :probe
        })

      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      body =
        conn |> management() |> get(~p"/v1/serving/health?since=#{future}") |> json_response(200)

      assert body["events"] == []
    end
  end

  describe "GET /v1/usage" do
    test "rolls usage up per deployment", %{conn: conn} do
      d = deployment(provider(), %{model_name: "usage-model"})

      Usage.record_usage(%{
        deployment_id: d.id,
        outcome: :success,
        tokens_in: 100,
        tokens_out: 50,
        latency_ms: 20,
        cost: Decimal.new("0.25")
      })

      body = conn |> management() |> get(~p"/v1/usage") |> json_response(200)

      assert body["group_by"] == "deployment"
      row = Enum.find(body["rows"], &(&1["deployment_id"] == d.id))
      assert row["model_name"] == "usage-model"
      assert row["requests"] == 1
      assert row["tokens_in"] == 100
      assert row["tokens_out"] == 50
      assert row["cost"] == 0.25
      assert body["next_since"]
    end

    test "groups along the requested axis", %{conn: conn} do
      d = deployment(provider())

      Usage.record_usage(%{
        deployment_id: d.id,
        outcome: :success,
        capability: :chat,
        tokens_in: 3
      })

      body = conn |> management() |> get(~p"/v1/usage?group_by=capability") |> json_response(200)

      assert body["group_by"] == "capability"
      assert Enum.find(body["rows"], &(&1["capability"] == "chat"))
    end
  end

  describe "GET /metrics" do
    test "exposes the topology in Prometheus format", %{conn: conn} do
      {:ok, agent} =
        Config.create_agent(%{
          host_id: "jobycorp",
          control_url: "http://jobycorp:4400",
          gpu: %{"available" => true, "vram_total_mb" => 24_564, "vram_used_mb" => 18_201}
        })

      slot = provider(%{agent_id: agent.id, name: "jobycorp:8080"})
      served = deployment(slot, %{model_name: "Qwen3.6-35B"})
      Health.mark(served.id, :up, 12)
      SlotState.put(slot.id, %{resident_model: "Qwen3.6-35B.gguf", status: "up", ctx: 32_768})

      response = conn |> management() |> get("/metrics")
      body = response(response, 200)

      assert ["text/plain; version=0.0.4; charset=utf-8"] =
               get_resp_header(response, "content-type")

      assert body =~ ~s(airo_host_vram_free_mb{host_id="jobycorp"} 6363.0)

      assert body =~
               ~s(airo_slot_status{host_id="jobycorp",slot="jobycorp:8080",model="Qwen3.6-35B.gguf",status="up"} 1)

      assert body =~ ~s(status="loading"} 0)

      assert body =~
               ~s(airo_slot_ctx{host_id="jobycorp",slot="jobycorp:8080",model="Qwen3.6-35B.gguf"} 32768)

      assert body =~ "# TYPE airo_deployment_health gauge"
      assert body =~ ~s(model_name="Qwen3.6-35B",deployment_id="#{served.id}",status="up"} 1)
      assert body =~ ~s(model_name="Qwen3.6-35B",deployment_id="#{served.id}",status="down"} 0)
      assert body =~ "airo_deployment_routable"
    end

    test "omits vram series for a host with no telemetry rather than reporting zero", %{
      conn: conn
    } do
      {:ok, _} =
        Config.create_agent(%{host_id: "dark", control_url: "http://dark:4400", gpu: %{}})

      body = conn |> management() |> get("/metrics") |> response(200)

      refute body =~ ~s(airo_host_vram_total_mb{host_id="dark"})
      assert body =~ ~s(airo_host_enabled{host_id="dark"} 1)
    end

    test "escapes label values that would otherwise break the exposition", %{conn: conn} do
      p = provider(%{name: ~s(weird"name)})
      deployment(p, %{model_name: ~s(model\\path)})

      body = conn |> management() |> get("/metrics") |> response(200)

      assert body =~ ~s(provider="weird\\"name")
      assert body =~ ~s(model_name="model\\\\path")
    end

    test "exposes multi-node loads as one cluster plus per-rank slots", %{conn: conn} do
      for {host, rank} <- [{"sparky", 0}, {"sparky2", 1}] do
        {:ok, _} = Config.create_agent(%{host_id: host, control_url: "http://#{host}:4400"})
        slot = provider(%{agent_id: Config.get_agent_by_host_id(host).id, name: "#{host}:8081"})

        SlotState.put(slot.id, %{
          resident_model: "DeepSeek-V4-Flash:fp8",
          status: "up",
          cluster_id: "dep-7f3a",
          tp_rank: rank,
          tp_size: 2
        })
      end

      body = conn |> management() |> get("/metrics") |> response(200)

      assert body =~ ~s(airo_cluster_serving{cluster="dep-7f3a",model="DeepSeek-V4-Flash:fp8"} 1)
      assert body =~ ~s(airo_cluster_complete{cluster="dep-7f3a",model="DeepSeek-V4-Flash:fp8"} 1)
      assert body =~ ~s(airo_cluster_members{cluster="dep-7f3a",model="DeepSeek-V4-Flash:fp8"} 2)

      # Only rank 0 answers inference, and each slot's series names its rank.
      assert body =~ ~s(airo_slot_serves_api{host_id="sparky",slot="sparky:8081"} 1)
      assert body =~ ~s(airo_slot_serves_api{host_id="sparky2",slot="sparky2:8081"} 0)

      assert body =~
               ~s(airo_slot_tp_rank{host_id="sparky2",slot="sparky2:8081",cluster="dep-7f3a"} 1)

      assert body =~
               ~s(model="DeepSeek-V4-Flash:fp8",status="up",cluster="dep-7f3a",tp_rank="1"} 1)
    end

    test "a cluster missing a rank reports not serving", %{conn: conn} do
      {:ok, _} = Config.create_agent(%{host_id: "sparky", control_url: "http://sparky:4400"})
      slot = provider(%{agent_id: Config.get_agent_by_host_id("sparky").id, name: "sparky:8081"})

      SlotState.put(slot.id, %{
        resident_model: "DeepSeek-V4-Flash:fp8",
        status: "up",
        cluster_id: "dep-7f3a",
        tp_rank: 0,
        tp_size: 2
      })

      body = conn |> management() |> get("/metrics") |> response(200)

      # The head's own slot is up, but the load is not servable.
      assert body =~
               ~s(airo_slot_status{host_id="sparky",slot="sparky:8081",model="DeepSeek-V4-Flash:fp8",status="up",cluster="dep-7f3a",tp_rank="0"} 1)

      assert body =~ ~s(airo_cluster_serving{cluster="dep-7f3a",model="DeepSeek-V4-Flash:fp8"} 0)
      assert body =~ ~s(airo_cluster_complete{cluster="dep-7f3a",model="DeepSeek-V4-Flash:fp8"} 0)
    end

    test "emits gpu utilisation and power when the host reports them", %{conn: conn} do
      {:ok, _} =
        Config.create_agent(%{
          host_id: "sparky",
          control_url: "http://sparky:4400",
          gpu: %{
            "available" => true,
            "vram_total_mb" => 124_546,
            "vram_used_mb" => 118_415,
            "util_pct" => 87.5,
            "power_draw_w" => 11.87
          }
        })

      body = conn |> management() |> get("/metrics") |> response(200)

      assert body =~ ~s(airo_host_gpu_util_pct{host_id="sparky"} 87.5)
      assert body =~ ~s(airo_host_power_draw_w{host_id="sparky"} 11.87)
    end

    test "emits usage counters per deployment", %{conn: conn} do
      d = deployment(provider(), %{model_name: "counted"})
      Usage.record_usage(%{deployment_id: d.id, outcome: :success, tokens_in: 7, tokens_out: 11})

      body = conn |> management() |> get("/metrics") |> response(200)

      assert body =~ "# TYPE airo_requests_total counter"
      assert body =~ ~s(model_name="counted",deployment_id="#{d.id}",direction="in"} 7)
      assert body =~ ~s(model_name="counted",deployment_id="#{d.id}",direction="out"} 11)
    end
  end
end

defmodule AiroWeb.ServingControllerHostsTest do
  # S25 — host liveness in the snapshot, the hosts endpoint, the metrics gauges.
  use AiroWeb.ConnCase, async: false

  alias Airo.Agents.Lifecycle
  alias Airo.Config
  alias Airo.Test.AgentControl

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.hosts_table())
    {:ok, agent} = Config.create_agent(%{host_id: "srv-host", control_url: "http://srv:4400"})
    %{agent: agent}
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

  defp management(conn),
    do: put_req_header(conn, "authorization", "Bearer " <> mint([:management]))

  defp host(conn) do
    conn
    |> management()
    |> get(~p"/v1/serving")
    |> json_response(200)
    |> Map.fetch!("hosts")
    |> Enum.find(&(&1["host_id"] == "srv-host"))
  end

  test "the snapshot carries online, stale and role per host", %{conn: conn, agent: agent} do
    assert %{"online" => false, "stale" => false, "role" => "controller"} = host(conn)

    {:ok, _} = Config.update_agent(agent, %{role: :observer})
    assert %{"role" => "observer"} = host(conn)

    AgentControl.mark_online("srv-host")
    assert %{"online" => true, "stale" => false} = host(conn)

    :ets.insert(
      Airo.Runtime.Store.hosts_table(),
      {{:stale, "srv-host"}, %{since: 0, silent_ms: 1}}
    )

    assert %{"online" => true, "stale" => true} = host(conn)
  end

  test "/metrics exposes the host online and stale gauges", %{conn: conn} do
    AgentControl.mark_online("srv-host")
    body = conn |> management() |> get(~p"/metrics") |> response(200)

    assert body =~ ~s(airo_host_online{host_id="srv-host"} 1)
    assert body =~ ~s(airo_host_stale{host_id="srv-host"} 0)
  end

  test "/v1/serving/hosts pages lifecycle events by cursor", %{conn: conn, agent: agent} do
    {:ok, first} = Lifecycle.transition("srv-host", :connected, meta: %{version: "0.1.0"})
    Lifecycle.transition("srv-host", :stale, reason: "no register for 47000ms")
    Lifecycle.transition("srv-host", :recovered)

    page = conn |> management() |> get(~p"/v1/serving/hosts?limit=2") |> json_response(200)

    assert page["has_more"] == true

    assert [
             %{"kind" => "connected", "agent_id" => agent_id, "meta" => %{"version" => "0.1.0"}},
             %{"kind" => "stale", "reason" => "no register for 47000ms"}
           ] = page["events"]

    assert agent_id == agent.id

    rest =
      conn
      |> management()
      |> get(~p"/v1/serving/hosts?since=#{page["next_since"]}")
      |> json_response(200)

    assert [%{"kind" => "recovered", "host_id" => "srv-host"}] = rest["events"]
    assert rest["has_more"] == false

    # A timestamp cursor works too, and excludes everything at or before it.
    after_first = first.inserted_at |> NaiveDateTime.add(1, :second) |> NaiveDateTime.to_iso8601()

    later =
      conn
      |> management()
      |> get(~p"/v1/serving/hosts?since=#{after_first}")
      |> json_response(200)

    refute Enum.any?(later["events"], &(&1["kind"] == "connected"))
  end

  test "/v1/serving/hosts needs the management scope", %{conn: conn} do
    conn
    |> put_req_header("authorization", "Bearer " <> mint([:inference]))
    |> get(~p"/v1/serving/hosts")
    |> json_response(403)
  end
end
