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
        capabilities: [capability]
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

  test "chat/stream attempts carry a generous upstream receive_timeout" do
    key = setup_model("qwen3.5-9b")

    for capability <- [:chat, :stream] do
      assert {:ok, plan} =
               Gateway.resolve(%{"model" => "qwen3.5-9b", "messages" => []}, key, capability)

      req_opts =
        plan.attempts
        |> hd()
        |> get_in([Access.key!(:context), Access.key!(:opts)])
        |> Keyword.get(:req_options, [])

      assert Keyword.get(req_opts, :receive_timeout) == 300_000
    end
  end

  test "non-chat capabilities keep the transport default receive_timeout" do
    key = setup_model("bge-m3", :embeddings)

    assert {:ok, plan} = Gateway.resolve(%{"model" => "bge-m3", "input" => "x"}, key, :embed)
    opts = plan.attempts |> hd() |> Map.fetch!(:context) |> Map.fetch!(:opts)
    refute Keyword.has_key?(Keyword.get(opts, :req_options, []), :receive_timeout)
  end

  test "the chat receive_timeout is overridable via app config" do
    key = setup_model("qwen3.5-9b")
    Application.put_env(:airo, Airo.Gateway, chat_receive_timeout: 123_456)
    on_exit(fn -> Application.delete_env(:airo, Airo.Gateway) end)

    assert {:ok, plan} = Gateway.resolve(%{"model" => "qwen3.5-9b", "messages" => []}, key, :chat)

    req_opts =
      plan.attempts
      |> hd()
      |> Map.fetch!(:context)
      |> Map.fetch!(:opts)
      |> Keyword.get(:req_options, [])

    assert Keyword.get(req_opts, :receive_timeout) == 123_456
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
        capabilities: [:chat]
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

  defp image_request(model) do
    %{
      "model" => model,
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "what is this?"},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}}
          ]
        }
      ]
    }
  end

  test "a vision-only model is served on the chat endpoint when the request carries an image" do
    key = setup_model("moondream:latest", :vision)
    Req.Test.stub(Airo.TestStub, fn upstream -> Req.Test.json(upstream, @completion) end)

    assert {:ok, plan} = Gateway.resolve(image_request("moondream:latest"), key, :chat)
    assert plan.usage_capability == :vision

    assert {:ok, _body, info} = Gateway.run(plan)
    assert info.served.deployment.model_name == "moondream:latest"
  end

  test "a vision-only model is NOT served for a text-only chat request" do
    key = setup_model("moondream:latest", :vision)
    # No image → the resource capability is :chat, which [:vision] does not serve.
    assert {:error, {:model_not_found, "moondream:latest"}} =
             Gateway.resolve(%{"model" => "moondream:latest", "messages" => []}, key, :chat)
  end

  test "a multimodal model serves both a text chat and an image request" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "p-mm-#{System.unique_integer([:positive])}",
        adapter_type: :vllm,
        base_url: "http://up/v1",
        auth_kind: :none
      })

    {:ok, _dep} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "qwen-mm",
        capabilities: [:chat, :vision]
      })

    {:ok, key} = Config.mint_client_key(%{name: "k-mm", allowed_aliases: ["*"]})

    assert {:ok, text_plan} =
             Gateway.resolve(%{"model" => "qwen-mm", "messages" => []}, key, :chat)

    assert text_plan.usage_capability == :chat

    assert {:ok, image_plan} = Gateway.resolve(image_request("qwen-mm"), key, :chat)
    assert image_plan.usage_capability == :vision
  end
end
