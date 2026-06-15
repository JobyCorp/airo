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
      Config.create_deployment(%{provider_id: p.id, model_name: model, capability: :chat})

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
