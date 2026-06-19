defmodule Airo.Config.AliasTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.Alias

  setup do
    {:ok, provider} =
      Config.create_provider(%{
        name: "local-vllm",
        adapter_type: :vllm,
        base_url: "http://localhost:8000/v1"
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "qwen3.5-9b",
        capabilities: [:chat]
      })

    %{deployment: deployment}
  end

  describe "changeset/2" do
    test "is valid with required fields and defaults strategy to :priority" do
      changeset = Alias.changeset(%Alias{}, %{name: "chat-standard", capability: :chat})
      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).strategy == :priority
    end

    test "requires name and capability" do
      errors = errors_on(Alias.changeset(%Alias{}, %{}))
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.capability
    end

    test "rejects an unknown strategy" do
      changeset = Alias.changeset(%Alias{}, %{name: "x", capability: :chat, strategy: :random})
      assert "is invalid" in errors_on(changeset).strategy
    end

    test "router defaults to :none and router_config to %{}" do
      alias_ =
        %Alias{}
        |> Alias.changeset(%{name: "x", capability: :chat})
        |> Ecto.Changeset.apply_changes()

      assert alias_.router == :none
      assert alias_.router_config == %{}
    end

    test "accepts router :classify with a config map" do
      changeset =
        Alias.changeset(%Alias{}, %{
          name: "chat",
          capability: :chat,
          router: :classify,
          router_config: %{"mode" => "shadow", "classifier" => "prompt-class"}
        })

      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.router == :classify
      assert applied.router_config == %{"mode" => "shadow", "classifier" => "prompt-class"}
    end

    test "rejects an unknown router" do
      changeset = Alias.changeset(%Alias{}, %{name: "x", capability: :chat, router: :bogus})
      assert "is invalid" in errors_on(changeset).router
    end

    test "router :classify needs no per-alias config (inherits the system classifier, S16)" do
      changeset = Alias.changeset(%Alias{}, %{name: "x", capability: :chat, router: :classify})
      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).router == :classify
    end

    test "router_mode defaults to :shadow and accepts :enforce" do
      default = Alias.changeset(%Alias{}, %{name: "x", capability: :chat})
      assert Ecto.Changeset.apply_changes(default).router_mode == :shadow

      enforced =
        Alias.changeset(%Alias{}, %{name: "x", capability: :chat, router_mode: :enforce})

      assert enforced.valid?
      assert Ecto.Changeset.apply_changes(enforced).router_mode == :enforce
    end
  end

  describe "candidates (cast_assoc)" do
    test "creates an alias with a routing candidate", %{deployment: deployment} do
      assert {:ok, alias_} =
               Config.create_alias(%{
                 name: "chat-standard",
                 capability: :chat,
                 strategy: :priority,
                 candidates: [%{deployment_id: deployment.id, weight: 100, priority: 0}]
               })

      assert [candidate] = Config.get_alias_by_name(alias_.name).candidates
      assert candidate.deployment_id == deployment.id
      assert candidate.weight == 100
    end

    test "rejects a candidate pointing at a missing deployment" do
      assert {:error, changeset} =
               Config.create_alias(%{
                 name: "chat-standard",
                 capability: :chat,
                 candidates: [%{deployment_id: -1, weight: 100, priority: 0}]
               })

      refute changeset.valid?
    end
  end
end
