defmodule Airo.GatewayInFlightTest do
  # The in-flight count is observed *from inside the stubbed upstream*, which
  # `Req.Test` runs in the calling process — so the plug sees exactly what the
  # deployment reads while the request is outstanding (S28).
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Gateway
  alias Airo.Gateway.InFlight

  setup do
    Airo.Test.Health.set_failure_threshold(1)
    :ok
  end

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

  defp alias_and_key(name, deployments) do
    {:ok, _} =
      Config.create_alias(%{
        name: name,
        capability: :chat,
        strategy: :priority,
        candidates:
          deployments
          |> Enum.with_index()
          |> Enum.map(fn {d, i} -> %{deployment_id: d.id, weight: 100, priority: i} end)
      })

    {:ok, key} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: [name]
      })

    key
  end

  defp plan!(key, name, capability \\ :chat) do
    {:ok, plan} = Gateway.resolve(%{"model" => name, "messages" => []}, key, capability)
    plan
  end

  test "a chat request counts 1 on its deployment for exactly the upstream call" do
    host = "h-#{System.unique_integer([:positive])}"
    d = deployment(provider(host), "m")
    key = alias_and_key("a-#{host}", [d])
    test = self()

    Req.Test.stub(Airo.TestStub, fn conn ->
      send(test, {:during, InFlight.count(d.id)})
      Req.Test.json(conn, @completion)
    end)

    assert InFlight.count(d.id) == 0
    assert {:ok, _body, _info} = Gateway.run(plan!(key, "a-#{host}"))
    assert_received {:during, 1}
    assert InFlight.count(d.id) == 0
  end

  test "a failover releases the first deployment before the second is called" do
    tag = System.unique_integer([:positive])
    down = deployment(provider("down-#{tag}"), "md")
    up = deployment(provider("up-#{tag}"), "mu")
    key = alias_and_key("ha-#{tag}", [down, up])
    test = self()

    Req.Test.stub(Airo.TestStub, fn conn ->
      case conn.host do
        "down-" <> _ ->
          send(test, {:down_during, InFlight.count(down.id), InFlight.count(up.id)})
          Req.Test.transport_error(conn, :econnrefused)

        "up-" <> _ ->
          send(test, {:up_during, InFlight.count(down.id), InFlight.count(up.id)})
          Req.Test.json(conn, @completion)
      end
    end)

    assert {:ok, _body, %{fallback_used: true}} = Gateway.run(plan!(key, "ha-#{tag}"))
    assert_received {:down_during, 1, 0}
    assert_received {:up_during, 0, 1}
    assert InFlight.count(down.id) == 0
    assert InFlight.count(up.id) == 0
  end

  test "an upstream error still releases" do
    host = "e-#{System.unique_integer([:positive])}"
    d = deployment(provider(host), "m")
    key = alias_and_key("a-#{host}", [d])

    Req.Test.stub(Airo.TestStub, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad"})
    end)

    assert {:error, {:http_error, 400, _}} = Gateway.run(plan!(key, "a-#{host}"))
    assert InFlight.count(d.id) == 0
  end

  test "a raising adapter releases before the exception reaches the caller" do
    host = "r-#{System.unique_integer([:positive])}"
    d = deployment(provider(host), "m")
    key = alias_and_key("a-#{host}", [d])

    Req.Test.stub(Airo.TestStub, fn _conn -> raise "upstream exploded" end)

    assert_raise RuntimeError, ~r/upstream exploded/, fn ->
      Gateway.run(plan!(key, "a-#{host}"))
    end

    assert InFlight.count(d.id) == 0
  end

  test "a streaming request counts 1 for the span of the stream and releases after" do
    host = "s-#{System.unique_integer([:positive])}"
    d = deployment(provider(host), "m")
    key = alias_and_key("a-#{host}", [d])
    test = self()

    Req.Test.stub(Airo.TestStub, fn conn ->
      send(test, {:during, InFlight.count(d.id)})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Req.Test.text(
        ~s(data: {"id":"c","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hi"}}]}\n\n) <>
          "data: [DONE]\n\n"
      )
    end)

    plan = plan!(key, "a-#{host}", :stream)
    reducer = fn delta, acc -> [delta | acc] end
    committed? = fn acc -> acc != [] end

    assert {:ok, deltas, _info} = Gateway.run_stream(plan, [], reducer, committed?)
    assert deltas != []
    assert_received {:during, 1}
    assert InFlight.count(d.id) == 0
  end
end
