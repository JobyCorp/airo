defmodule Airo.Adapter.Context do
  @moduledoc """
  Per-call context handed to an `Airo.Adapter` callback.

  - `:provider` — the `Airo.Config.Provider` whose `base_url`/credential/auth the
    call targets. Its `:credential` association should be loaded (or nil for
    keyless upstreams).
  - `:deployment` — the concrete `Airo.Config.Deployment` chosen by routing, or
    nil. When present, its `model_name` is the upstream model to send.
  - `:opts` — per-call knobs. Recognized keys:
      - `:req_options` — extra options merged into the underlying `Req` request
        (e.g. `plug: {Req.Test, Stub}` in tests, `receive_timeout:`).
  """

  alias Airo.Config.{Deployment, Provider}

  @enforce_keys [:provider]
  defstruct provider: nil, deployment: nil, opts: []

  @type t :: %__MODULE__{
          provider: Provider.t(),
          deployment: Deployment.t() | nil,
          opts: keyword()
        }

  @doc "Build a context from a provider and optional fields."
  def new(%Provider{} = provider, fields \\ []) do
    struct!(%__MODULE__{provider: provider}, fields)
  end
end
