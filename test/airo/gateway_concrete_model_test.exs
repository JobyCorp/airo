defmodule Airo.GatewayConcreteModelTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Gateway

  @completion %{
    "object" => "chat.completion",
    "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}}]
  }

  defp setup_model(model, capability \\ :chat) do
    {:ok, provider} =
      Config.create_provider(%{
        name: "p-#{System.unique_integer([:positive])}",
        adapter_type: :vllm,
        base_url: "http://up/v1",
        auth_kind: :none
      })

    {:ok, _deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: model,
        capability: capability
      })

    {:ok, key} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: ["*"]
      })

    key
  end

  test "resolves a concrete deployment model id directly (no alias)" do
    key = setup_model("qwen3.5-9b")
    Req.Test.stub(Airo.TestStub, fn upstream -> Req.Test.json(upstream, @completion) end)

    assert {:ok, plan} = Gateway.resolve(%{"model" => "qwen3.5-9b", "messages" => []}, key, :chat)
    assert plan.model == "qwen3.5-9b"
    assert plan.usage_capability == :chat

    assert {:ok, body, info} = Gateway.run(plan)
    assert body["choices"] |> hd() |> get_in(["message", "content"]) == "ok"
    assert info.served.deployment.model_name == "qwen3.5-9b"
    refute info.fallback_used
  end

  test "maps the request capability to the deployment capability (embed → embeddings)" do
    key = setup_model("bge-m3", :embeddings)

    Req.Test.stub(Airo.TestStub, fn upstream ->
      Req.Test.json(upstream, %{"data" => [%{"embedding" => [0.1]}]})
    end)

    assert {:ok, plan} = Gateway.resolve(%{"model" => "bge-m3", "input" => "x"}, key, :embed)
    assert plan.usage_capability == :embeddings
    assert {:ok, _body, _info} = Gateway.run(plan)
  end

  test "a model id only resolves for the matching capability" do
    key = setup_model("bge-m3", :embeddings)
    # No chat deployment named bge-m3 → not found on the chat path.
    assert {:error, {:model_not_found, "bge-m3"}} =
             Gateway.resolve(%{"model" => "bge-m3", "messages" => []}, key, :chat)
  end

  test "an alias still wins over a concrete model of the same name" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "pa",
        adapter_type: :vllm,
        base_url: "http://up/v1",
        auth_kind: :none
      })

    {:ok, dep} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "shared",
        capability: :chat
      })

    {:ok, _alias} =
      Config.create_alias(%{
        name: "shared",
        capability: :chat,
        strategy: :priority,
        candidates: [%{deployment_id: dep.id, weight: 100, priority: 0}]
      })

    {:ok, key} = Config.mint_client_key(%{name: "k", allowed_aliases: ["*"]})

    assert {:ok, plan} = Gateway.resolve(%{"model" => "shared", "messages" => []}, key, :chat)
    # alias capability path sets usage_capability from the alias.
    assert plan.usage_capability == :chat
  end

  test "unknown model id is model_not_found" do
    key = setup_model("qwen3.5-9b")

    assert {:error, {:model_not_found, "ghost"}} =
             Gateway.resolve(%{"model" => "ghost", "messages" => []}, key, :chat)
  end
end
