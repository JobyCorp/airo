defmodule Airo.Agents.ProvenanceTest do
  use Airo.DataCase, async: true

  alias Airo.Agents.Provenance
  alias Airo.Config

  @resident "unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL"
  @gguf "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
  @path "/cache/models--unsloth--Qwen3.6-35B-A3B-MTP-GGUF/snapshots/5bc3e238/#{@gguf}"

  defp agent(host_id) do
    {:ok, agent} =
      Config.create_agent(%{host_id: host_id, control_url: "http://#{host_id}:4400"})

    agent
  end

  defp slot_provider(agent, port) do
    {:ok, provider} =
      Config.create_provider(%{
        name: "#{agent.host_id}:#{port}",
        adapter_type: :openai,
        base_url: "http://#{agent.host_id}:#{port}/v1",
        auth_kind: :none,
        agent_id: agent.id
      })

    provider
  end

  defp slot(port \\ 8081),
    do: %{
      "resident_model" => @resident,
      "revision" => "5bc3e238",
      "port" => port,
      "status" => "up"
    }

  defp provenance do
    %{
      "id" => @resident,
      "family" => "qwen35moe",
      "quant" => "UD-Q4_K_XL",
      "size_bytes" => 22_853_663_008,
      "path" => @path,
      "revision" => "5bc3e238"
    }
  end

  test "creates a host/slot-qualified Model with the real name as display_name" do
    a = agent("jobycorp")
    provider = slot_provider(a, 8081)

    model = Provenance.reconcile("jobycorp", provider, slot(), provenance())

    assert model.upstream_model_id == "jobycorp_#{@resident}_8081"
    assert model.display_name == @resident
    assert model.family == "qwen35moe"
    assert model.quantization == "UD-Q4_K_XL"
    assert model.size == "21.3 GB"
    assert model.revision == "5bc3e238"
  end

  test "re-keys a legacy filename-named Model in place and keeps its deployment" do
    a = agent("jobycorp")
    provider = slot_provider(a, 8081)
    {:ok, legacy} = Config.create_model(%{display_name: @gguf, upstream_model_id: @gguf})

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_id: legacy.id,
        model_name: @gguf,
        capabilities: [:chat]
      })

    model = Provenance.reconcile("jobycorp", provider, slot(), provenance())

    # same record, re-keyed + enriched — not a duplicate
    assert model.id == legacy.id
    assert model.upstream_model_id == "jobycorp_#{@resident}_8081"
    assert model.display_name == @resident
    assert Config.get_deployment!(deployment.id).model_id == legacy.id
  end

  test "the legacy re-key is scoped to the slot provider — never an external Model" do
    a = agent("jobycorp")
    slot_p = slot_provider(a, 8081)

    {:ok, external} =
      Config.create_provider(%{
        name: "ext",
        adapter_type: :vllm,
        base_url: "http://x/v1",
        auth_kind: :none
      })

    {:ok, ext_model} = Config.create_model(%{display_name: @gguf, upstream_model_id: @gguf})

    {:ok, _} =
      Config.create_deployment(%{
        provider_id: external.id,
        model_id: ext_model.id,
        model_name: @gguf,
        capabilities: [:chat]
      })

    model = Provenance.reconcile("jobycorp", slot_p, slot(), provenance())

    # the external Model is untouched; a fresh canonical Model is created instead
    refute model.id == ext_model.id
    assert Config.get_model!(ext_model.id).upstream_model_id == @gguf
  end

  test "reconciling twice is idempotent (find by key, enrich, no duplicate)" do
    a = agent("jobycorp")
    provider = slot_provider(a, 8081)

    m1 = Provenance.reconcile("jobycorp", provider, slot(), provenance())
    m2 = Provenance.reconcile("jobycorp", provider, slot(), provenance())

    assert m1.id == m2.id
    assert length(Config.list_models()) == 1
  end

  test "identity-only reconcile when provenance is unavailable" do
    a = agent("jobycorp")
    provider = slot_provider(a, 8081)

    model = Provenance.reconcile("jobycorp", provider, slot(), nil)

    assert model.upstream_model_id == "jobycorp_#{@resident}_8081"
    assert model.display_name == @resident
    assert model.revision == "5bc3e238"
    assert model.family == nil
  end

  test "an empty slot reconciles to nil" do
    a = agent("jobycorp")
    provider = slot_provider(a, 8081)

    assert Provenance.reconcile("jobycorp", provider, %{"port" => 8081, "status" => "empty"}, nil) ==
             nil
  end
end
