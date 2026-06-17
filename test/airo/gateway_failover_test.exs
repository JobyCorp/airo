defmodule Airo.GatewayFailoverTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Gateway
  alias Airo.Health

  @completion %{
    "id" => "chatcmpl-1",
    "object" => "chat.completion",
    "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}}]
  }

  defp provider(name) do
    {:ok, p} =
      Config.create_provider(%{
        name: name,
        adapter_type: :vllm,
        base_url: "http://#{name}/v1",
        auth_kind: :none
      })

    p
  end

  defp deployment(provider, model) do
    {:ok, d} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: model,
        capabilities: [:chat]
      })

    d
  end

  defp two_candidate_alias do
    down = deployment(provider("down"), "md")
    up = deployment(provider("up"), "mu")

    {:ok, _} =
      Config.create_alias(%{
        name: "ha",
        capability: :chat,
        strategy: :priority,
        candidates: [
          %{deployment_id: down.id, weight: 100, priority: 0},
          %{deployment_id: up.id, weight: 100, priority: 1}
        ]
      })

    {:ok, key} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: ["ha"]
      })

    key
  end

  defp resolve!(key, capability \\ :chat) do
    {:ok, plan} = Gateway.resolve(%{"model" => "ha", "messages" => []}, key, capability)
    plan
  end

  test "fails over from a downed primary to the next candidate" do
    key = two_candidate_alias()

    Req.Test.stub(Airo.TestStub, fn conn ->
      case conn.host do
        "down" -> Req.Test.transport_error(conn, :econnrefused)
        "up" -> Req.Test.json(conn, @completion)
      end
    end)

    assert {:ok, body, info} = Gateway.run(resolve!(key))
    assert body["choices"] |> hd() |> get_in(["message", "content"]) == "ok"
    assert info.fallback_used
    assert info.served.provider.name == "up"
  end

  test "fails over on a 5xx primary" do
    key = two_candidate_alias()

    Req.Test.stub(Airo.TestStub, fn conn ->
      case conn.host do
        "down" -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "busy"})
        "up" -> Req.Test.json(conn, @completion)
      end
    end)

    assert {:ok, _body, info} = Gateway.run(resolve!(key))
    assert info.fallback_used
    assert info.served.provider.name == "up"
  end

  test "does NOT fail over on a 4xx (client error) from the primary" do
    key = two_candidate_alias()

    Req.Test.stub(Airo.TestStub, fn conn ->
      case conn.host do
        "down" -> conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
        "up" -> Req.Test.json(conn, @completion)
      end
    end)

    assert {:error, {:http_error, 400, _body}} = Gateway.run(resolve!(key))
  end

  test "no fallback_used when the primary succeeds" do
    key = two_candidate_alias()
    Req.Test.stub(Airo.TestStub, fn conn -> Req.Test.json(conn, @completion) end)

    assert {:ok, _body, info} = Gateway.run(resolve!(key))
    refute info.fallback_used
    assert info.served.provider.name == "down"
  end

  # A dispatch is stronger health signal than the periodic prober: record it.
  defp health_alias(primary_host) do
    down = deployment(provider(primary_host), "m-#{primary_host}")
    up = deployment(provider("up-#{primary_host}"), "mu-#{primary_host}")
    name = "ha-#{primary_host}"

    {:ok, _} =
      Config.create_alias(%{
        name: name,
        capability: :chat,
        strategy: :priority,
        candidates: [
          %{deployment_id: down.id, weight: 100, priority: 0},
          %{deployment_id: up.id, weight: 100, priority: 1}
        ]
      })

    {:ok, key} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: [name]
      })

    {key, name, down, up}
  end

  test "live health: a transport-error primary is marked :down, the server :up" do
    {key, name, down, up} = health_alias("downh")

    Req.Test.stub(Airo.TestStub, fn conn ->
      case conn.host do
        "downh" -> Req.Test.transport_error(conn, :econnrefused)
        "up-downh" -> Req.Test.json(conn, @completion)
      end
    end)

    {:ok, plan} = Gateway.resolve(%{"model" => name, "messages" => []}, key, :chat)
    assert {:ok, _body, _info} = Gateway.run(plan)

    assert Health.status(down.id) == :down
    assert Health.status(up.id) == :up
  end

  test "live health: a 4xx primary stays :up (reachable, not a host fault)" do
    {key, name, down, _up} = health_alias("badreq")

    Req.Test.stub(Airo.TestStub, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
    end)

    {:ok, plan} = Gateway.resolve(%{"model" => name, "messages" => []}, key, :chat)
    assert {:error, {:http_error, 400, _}} = Gateway.run(plan)

    assert Health.status(down.id) == :up
  end
end
