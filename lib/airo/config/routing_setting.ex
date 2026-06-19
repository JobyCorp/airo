defmodule Airo.Config.RoutingSetting do
  @moduledoc """
  The **system-level classifier** (S16). One singleton row holds how Airo grades
  prompts for classification-driven routing: the engine (`backend`), its model
  (local `model` / remote `classifier` alias), the `score` weighting, the tier
  ladder (`labels`), and the shared `default_class` / `input` / `timeout_ms`.

  Routed aliases only opt in (`Alias.router` + `Alias.router_mode`) and inherit
  this — they no longer carry their own classifier config. See
  DESIGN-routing-settings.md. Enforced as a singleton via a unique `singleton`
  flag; read it through `Airo.Config.get_routing_setting/0`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @backends [:infinity, :ortex]
  @inputs [:last_user, :all]

  @type t :: %__MODULE__{}

  schema "routing_settings" do
    field :backend, Ecto.Enum, values: @backends, default: :infinity
    # Remote (infinity): the :classify-capability alias name to call.
    field :classifier, :string
    # Local (ortex): the model dir under priv/models/.
    field :model, :string
    # ortex weighting: %{dim => weight}; empty map ⇒ the model's own "overall".
    field :score, :map, default: %{}
    # Tier ladder, ordered highest-first: [%{"class" => _, "min" => _}, ...].
    field :labels, {:array, :map}, default: []
    field :default_class, :string, default: "edge"
    field :input, Ecto.Enum, values: @inputs, default: :last_user
    field :timeout_ms, :integer, default: 200
    # Infinity only: rendered per label into the NLI hypothesis (`{}` → label).
    field :hypothesis_template, :string, default: "This request requires {}."
    # Singleton guard — always true, unique.
    field :singleton, :boolean, default: true

    timestamps()
  end

  @doc "Enum values for `backend`."
  def backends, do: @backends

  @doc "Enum values for `input`."
  def inputs, do: @inputs

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :backend,
      :classifier,
      :model,
      :score,
      :labels,
      :default_class,
      :input,
      :timeout_ms,
      :hypothesis_template
    ])
    |> put_change(:singleton, true)
    |> validate_required([:backend, :default_class, :input, :timeout_ms])
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_labels()
    |> validate_backend_target()
    |> unique_constraint(:singleton)
  end

  # A usable ladder needs at least one well-formed {class, min} row.
  defp validate_labels(changeset) do
    labels = get_field(changeset, :labels) || []

    if labels != [] and Enum.all?(labels, &valid_label?/1) do
      changeset
    else
      add_error(changeset, :labels, "must be a non-empty list of %{class, min}")
    end
  end

  defp valid_label?(%{"class" => c, "min" => m}) when is_binary(c) and is_number(m), do: true
  defp valid_label?(_), do: false

  # Remote needs a classifier alias; local needs a model.
  defp validate_backend_target(changeset) do
    case get_field(changeset, :backend) do
      :ortex ->
        require_present(changeset, :model, "is required for the local (ortex) backend")

      _ ->
        require_present(changeset, :classifier, "is required for the remote (infinity) backend")
    end
  end

  defp require_present(changeset, field, msg) do
    case get_field(changeset, field) do
      v when is_binary(v) ->
        if String.trim(v) == "", do: add_error(changeset, field, msg), else: changeset

      _ ->
        add_error(changeset, field, msg)
    end
  end
end
