defmodule Airo.Config.RoutingSettingTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.RoutingSetting

  defp valid_labels, do: [%{"class" => "deep", "min" => 0.5}]

  describe "changeset" do
    test "remote (infinity) requires a classifier" do
      cs =
        RoutingSetting.changeset(%RoutingSetting{}, %{backend: :infinity, labels: valid_labels()})

      refute cs.valid?
      assert "is required for the remote (infinity) backend" in errors_on(cs).classifier
    end

    test "local (ortex) requires a model" do
      cs = RoutingSetting.changeset(%RoutingSetting{}, %{backend: :ortex, labels: valid_labels()})
      refute cs.valid?
      assert "is required for the local (ortex) backend" in errors_on(cs).model
    end

    test "requires a non-empty tier ladder" do
      cs =
        RoutingSetting.changeset(%RoutingSetting{}, %{
          backend: :infinity,
          classifier: "prompt-class",
          labels: []
        })

      refute cs.valid?
      assert errors_on(cs).labels != []
    end
  end

  describe "routing_config/0" do
    test "ortex weights map round-trips; empty weights ⇒ :overall" do
      {:ok, _} =
        Config.update_routing_setting(%{
          backend: :ortex,
          model: "m",
          labels: [%{"class" => "deep", "min" => 0.2}],
          score: %{"constraint" => 0.55}
        })

      cfg = Config.routing_config()
      assert cfg.backend == :ortex
      assert cfg.model == "m"
      assert cfg.score == %{"constraint" => 0.55}
      assert cfg.labels == [%{label: nil, class: "deep", min: 0.2}]

      {:ok, _} =
        Config.update_routing_setting(%{
          backend: :infinity,
          classifier: "prompt-class",
          labels: valid_labels(),
          score: %{}
        })

      assert Config.routing_config().score == :overall
    end
  end
end
