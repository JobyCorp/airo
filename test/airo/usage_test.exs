defmodule Airo.UsageTest do
  # async: false so the SQL sandbox runs in shared mode and the off-path
  # Task.Supervisor process can write to the DB.
  use Airo.DataCase, async: false

  alias Airo.{Config, Usage}
  alias Airo.Config.Deployment

  @response %{
    "choices" => [%{"finish_reason" => "stop"}],
    "usage" => %{"prompt_tokens" => 1000, "completion_tokens" => 500}
  }

  describe "build_attrs/1" do
    test "extracts tokens + finish reason and computes cost from pricing" do
      deployment = %Deployment{
        id: 7,
        price_input: Decimal.new("0.002"),
        price_output: Decimal.new("0.006")
      }

      attrs =
        Usage.build_attrs(%{
          served: %{deployment: deployment},
          alias_name: "chat-deep",
          capability: :chat,
          response: @response,
          latency_ms: 42
        })

      assert attrs.tokens_in == 1000
      assert attrs.tokens_out == 500
      assert attrs.finish_reason == "stop"
      assert attrs.deployment_id == 7
      # 1000/1000 * 0.002 + 500/1000 * 0.006 = 0.002 + 0.003 = 0.005
      assert Decimal.equal?(attrs.cost, Decimal.new("0.005"))
    end

    test "cost is nil when the deployment has no pricing" do
      attrs =
        Usage.build_attrs(%{
          served: %{deployment: %Deployment{id: 1}},
          capability: :chat,
          response: @response
        })

      assert attrs.cost == nil
    end

    test "tokens default to zero without a usage block" do
      attrs = Usage.build_attrs(%{capability: :speech, response: nil})
      assert {attrs.tokens_in, attrs.tokens_out} == {0, 0}
      assert attrs.deployment_id == nil
    end
  end

  describe "record_async/1" do
    test "writes a usage record off the response path" do
      {:ok, provider} =
        Config.create_provider(%{
          name: "p",
          adapter_type: :vllm,
          base_url: "http://p/v1",
          auth_kind: :none
        })

      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: provider.id,
          model_name: "m",
          capability: :chat,
          price_input: Decimal.new("0.001"),
          price_output: Decimal.new("0.002")
        })

      {:ok, key} = Config.mint_client_key(%{name: "k", allowed_aliases: ["*"]})

      :ok =
        Usage.record_async(%{
          client_key: key,
          served: %{deployment: deployment},
          alias_name: "chat-standard",
          capability: :chat,
          response: @response,
          latency_ms: 10
        })

      record = eventually(fn -> List.first(Usage.list_usage_records()) end)
      assert record.alias_name == "chat-standard"
      assert record.tokens_in == 1000
      assert record.deployment_id == deployment.id
      assert Decimal.equal?(record.cost, Decimal.new("0.002"))
    end
  end

  defp eventually(fun, retries \\ 50) do
    case fun.() do
      nil when retries > 0 -> Process.sleep(10) && eventually(fun, retries - 1)
      result -> result
    end
  end
end
