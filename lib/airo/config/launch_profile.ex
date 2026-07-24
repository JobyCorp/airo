defmodule Airo.Config.LaunchProfile do
  @moduledoc """
  A saved launch recipe for a model on the managed fleet — the `profile` map the
  agent's `POST /load` accepts (engine flags, container `image`/`container_env`,
  cluster topology like `nnodes`/`tensor_parallel_size`, `extra_argv`, …).

  Keyed by the inventory model id (`model_name`), not by host: the recipe is a
  property of the model build. It exists so a hand-tuned launch — e.g. a
  two-node DSpark run with a purpose-built image and a raft of NCCL env — is
  typed once and survives unload/reload; the agent config modal reads it to
  prefill and re-saves it on every load.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "launch_profiles" do
    field :model_name, :string
    field :profile, :map, default: %{}

    timestamps()
  end

  def changeset(launch_profile, attrs) do
    launch_profile
    |> cast(attrs, [:model_name, :profile])
    |> validate_required([:model_name, :profile])
    |> unique_constraint(:model_name)
  end
end
