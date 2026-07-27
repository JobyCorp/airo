defmodule Airo.Config.Model do
  @moduledoc """
  Durable model identity for the Model Shelf.

  A model is the artifact/version Airo operators evaluate and manage. A
  deployment is still the runnable copy of that model on a provider machine.

  `engine` names the backend serving it (`"llama_cpp"`, `"vllm"`, …), sourced
  from the agent's `/inventory`. It matters because the engines are **not
  interchangeable behind the OpenAI wire**: llama.cpp's `-c` is `ctx × parallel`
  while vLLM's `--max-model-len` is the per-request window, llama.cpp honours
  sampling knobs at launch and vLLM honours none, and only vLLM exposes
  `/metrics`. Every agent-managed slot is `adapter_type: :openai` whatever runs
  behind it — that field names the *wire protocol* — so this is the only thing
  that distinguishes them.

  Null for external providers: there the provider's `adapter_type` already
  identifies the backend.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.Deployment

  @statuses [:evaluating, :preferred, :deprecated, :disabled]

  @type t :: %__MODULE__{}

  schema "models" do
    field :display_name, :string
    field :family, :string
    field :upstream_model_id, :string
    field :version, :string
    field :revision, :string
    field :quantization, :string
    field :size, :string
    field :engine, :string
    field :status, Ecto.Enum, values: @statuses, default: :evaluating
    field :notes, :string

    has_many :deployments, Deployment

    timestamps()
  end

  @doc "Enum values for `status`."
  def statuses, do: @statuses

  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :display_name,
      :family,
      :upstream_model_id,
      :version,
      :revision,
      :quantization,
      :size,
      :engine,
      :status,
      :notes
    ])
    |> validate_required([:display_name, :upstream_model_id, :status])
  end
end
