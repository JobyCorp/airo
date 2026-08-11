defmodule Airo.Agents.IngestContextTest do
  @moduledoc """
  Slot ingest keeps the resident deployment's `context_window` — what
  `/v1/models` publishes as `context_length` — in step with the serving
  context the engine actually reports, so consumers size against reality
  without an operator re-entering numbers on every relaunch.
  """
  use Airo.DataCase, async: false

  alias Airo.Agents.Ingest
  alias Airo.Config

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.health_table())
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
    :ok
  end

  @model "unsloth/Qwen3.6-35B-A3B-GGUF:Q6_K"

  defp agent(host_id) do
    {:ok, agent} =
      Config.create_agent(%{host_id: host_id, control_url: "http://#{host_id}:4400"})

    agent
  end

  defp push(host_id, attrs) do
    slot =
      Map.merge(
        %{
          "port" => 8081,
          "base_url" => "http://#{host_id}:8081/v1",
          "resident_model" => @model,
          "status" => "up"
        },
        attrs
      )

    :ok = Ingest.register(host_id, %{"agent" => %{}, "slots" => [slot]})
    Config.get_provider_by_name("#{host_id}:8081")
  end

  defp bound_deployment(host_id, attrs \\ %{}) do
    provider = push(host_id, attrs)

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: @model,
        capabilities: [:chat]
      })

    deployment
  end

  test "an up slot's reported ctx becomes the deployment's context_window" do
    agent("jobycorp")
    deployment = bound_deployment("jobycorp")

    push("jobycorp", %{"ctx" => 51_200})

    assert Config.get_deployment!(deployment.id).context_window == 51_200
  end

  test "a relaunch at a different ctx re-syncs the window" do
    agent("jobycorp")
    deployment = bound_deployment("jobycorp")

    push("jobycorp", %{"ctx" => 51_200})
    push("jobycorp", %{"ctx" => 32_768})

    assert Config.get_deployment!(deployment.id).context_window == 32_768
  end

  test "a push carrying only the engine total divides it across parallel sequences" do
    agent("jobycorp")
    deployment = bound_deployment("jobycorp")

    push("jobycorp", %{"ctx_total" => 204_800, "parallel" => 4})

    assert Config.get_deployment!(deployment.id).context_window == 51_200
  end

  test "a push with no serving context leaves an operator-set window alone" do
    agent("jobycorp")
    deployment = bound_deployment("jobycorp")
    {:ok, _} = Config.update_deployment(deployment, %{context_window: 40_960})

    push("jobycorp", %{})

    assert Config.get_deployment!(deployment.id).context_window == 40_960
  end

  test "a non-resident deployment's window is not touched" do
    agent("jobycorp")
    provider = push("jobycorp", %{"ctx" => 51_200})

    {:ok, other} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "some-other-model",
        capabilities: [:chat],
        context_window: 8_192
      })

    push("jobycorp", %{"ctx" => 51_200})

    assert Config.get_deployment!(other.id).context_window == 8_192
  end
end
