defmodule AiroWeb.ModelsControllerTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.Config

  defp provider_deployment(model) do
    {:ok, p} =
      Config.create_provider(%{
        name: "p-#{System.unique_integer([:positive])}",
        adapter_type: :vllm,
        base_url: "http://p/v1",
        auth_kind: :none
      })

    {:ok, d} =
      Config.create_deployment(%{provider_id: p.id, model_name: model, capabilities: [:chat]})

    d
  end

  defp create_alias(name, model) do
    d = provider_deployment(model)

    {:ok, _} =
      Config.create_alias(%{
        name: name,
        capability: :chat,
        strategy: :priority,
        candidates: [%{deployment_id: d.id, weight: 100, priority: 0}]
      })
  end

  defp mint(allowed),
    do:
      elem(
        Config.mint_client_key(%{
          name: "k-#{System.unique_integer([:positive])}",
          allowed_aliases: allowed
        }),
        1
      ).key

  defp authed(conn, key), do: put_req_header(conn, "authorization", "Bearer " <> key)

  defp ids(conn), do: json_response(conn, 200)["data"] |> Enum.map(& &1["id"]) |> Enum.sort()

  test "lists aliases and concrete deployment models for a wildcard-scoped key", %{conn: conn} do
    create_alias("chat-standard", "qwen3.5-9b")
    create_alias("chat-deep", "llama-70b")

    conn = conn |> authed(mint(["*"])) |> get(~p"/v1/models")

    body = json_response(conn, 200)
    assert body["object"] == "list"
    # both the aliases and the concrete deployment model ids are callable.
    assert ids(conn) == ["chat-deep", "chat-standard", "llama-70b", "qwen3.5-9b"]
    assert Enum.all?(body["data"], &(&1["object"] == "model"))
    # each entry advertises its capabilities so a client knows the endpoint.
    assert Enum.all?(body["data"], &(&1["capabilities"] == ["chat"]))
  end

  test "annotates a non-chat model id with its capability", %{conn: conn} do
    {:ok, p} =
      Config.create_provider(%{
        name: "emb-#{System.unique_integer([:positive])}",
        adapter_type: :infinity,
        base_url: "http://emb/v1",
        auth_kind: :none
      })

    {:ok, _} =
      Config.create_deployment(%{
        provider_id: p.id,
        model_name: "bge",
        capabilities: [:embeddings]
      })

    conn = conn |> authed(mint(["*"])) |> get(~p"/v1/models")
    entry = json_response(conn, 200)["data"] |> Enum.find(&(&1["id"] == "bge"))
    assert entry["capabilities"] == ["embeddings"]
  end

  test "advertises context_length as the min window across serving copies", %{conn: conn} do
    {:ok, p} =
      Config.create_provider(%{
        name: "ctx-#{System.unique_integer([:positive])}",
        adapter_type: :vllm,
        base_url: "http://ctx/v1",
        auth_kind: :none
      })

    {:ok, big} =
      Config.create_deployment(%{
        provider_id: p.id,
        model_name: "qwen3.5-9b",
        capabilities: [:chat],
        context_window: 131_072
      })

    {:ok, p2} =
      Config.create_provider(%{
        name: "ctx2-#{System.unique_integer([:positive])}",
        adapter_type: :vllm,
        base_url: "http://ctx2/v1",
        auth_kind: :none
      })

    # A second, smaller-window copy of the same model on another host.
    {:ok, small} =
      Config.create_deployment(%{
        provider_id: p2.id,
        model_name: "qwen3.5-9b",
        capabilities: [:chat],
        context_window: 32_768
      })

    # A disabled huge-window copy must not raise the bound.
    {:ok, _disabled} =
      Config.create_deployment(%{
        provider_id: p2.id,
        model_name: "no-window",
        capabilities: [:chat],
        context_window: 1_000_000,
        enabled: false
      })

    {:ok, _} =
      Config.create_alias(%{
        name: "chat-standard",
        capability: :chat,
        strategy: :priority,
        candidates: [
          %{deployment_id: big.id, weight: 100, priority: 0},
          %{deployment_id: small.id, weight: 100, priority: 1}
        ]
      })

    entries =
      conn
      |> authed(mint(["*"]))
      |> get(~p"/v1/models")
      |> json_response(200)
      |> Map.get("data")
      |> Map.new(&{&1["id"], &1["context_length"]})

    # The alias is bounded by its smallest candidate; the model id likewise
    # spans both copies; an id with no enabled window declared is null.
    assert entries["chat-standard"] == 32_768
    assert entries["qwen3.5-9b"] == 32_768
    assert entries["no-window"] == nil
  end

  test "lists only the names the client key is scoped to", %{conn: conn} do
    create_alias("chat-standard", "qwen3.5-9b")
    create_alias("chat-deep", "llama-70b")

    conn = conn |> authed(mint(["chat-deep"])) |> get(~p"/v1/models")
    assert ids(conn) == ["chat-deep"]
  end

  test "401 without a client key", %{conn: conn} do
    assert conn |> get(~p"/v1/models") |> json_response(401)
  end
end
