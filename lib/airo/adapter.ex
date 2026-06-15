defmodule Airo.Adapter do
  @moduledoc """
  The contract every upstream backend implements (DESIGN §6).

  One module per upstream *type* (not per provider instance) — e.g.
  `Airo.Adapters.OpenAICompatible` fronts vLLM/Ollama/LM Studio/OpenAI/Speaches,
  while Anthropic and Infinity get bespoke modules that normalize their wire
  format to OpenAI shape. `Airo.Registry` maps an `adapter_type` to its module.

  Each capability is a separate callback and all are **optional**: an embeddings
  provider implements `embed/2` only, a chat provider `chat/2`, etc. Use
  `supports?/2` to check before dispatching.

  Requests and responses are OpenAI-shaped maps (string keys, as decoded from
  JSON). Normalization of non-OpenAI upstreams happens *inside* the adapter, so
  callers above the adapter layer only ever see OpenAI shape.

  Per-call state (which provider, which concrete deployment, request options)
  travels in an `Airo.Adapter.Context`.
  """

  alias Airo.Adapter.Context

  @typedoc "OpenAI-shaped request body (string-keyed map as received/decoded)."
  @type params :: map()

  @typedoc "OpenAI-shaped response body, or an error reason."
  @type result :: {:ok, map()} | {:error, term()}

  @doc "Chat completion (non-streaming). Body is OpenAI `/chat/completions` shaped."
  @callback chat(params, Context.t()) :: result

  @typedoc """
  Reduces normalized OpenAI delta chunks into an accumulator — the streaming
  analogue of `Enum.reduce/3`'s function. The caller (e.g. the controller)
  threads its own state through `acc` (typically the `Plug.Conn` it chunks to).
  """
  @type stream_reducer :: (map(), acc :: term() -> term())

  @doc """
  Streaming chat. Folds each normalized OpenAI delta chunk into `acc` via
  `reducer` and returns the final accumulator. The terminal `[DONE]` sentinel is
  consumed, not forwarded.

  On failure the accumulator is returned alongside the reason so the caller can
  tell whether anything was already emitted (and thus whether failover is still
  possible). For a pre-response failure (connection refused, non-2xx) the
  accumulator is unchanged.
  """
  @callback stream(params, Context.t(), acc :: term(), stream_reducer) ::
              {:ok, term()} | {:error, term(), acc :: term()}

  @doc "Embeddings. Body is OpenAI `/embeddings` shaped."
  @callback embed(params, Context.t()) :: result

  @doc "Rerank. Jina/Cohere `/rerank` shaped (OpenAI defines none)."
  @callback rerank(params, Context.t()) :: result

  @doc "Text-to-speech. OpenAI `/audio/speech` shaped."
  @callback speech(params, Context.t()) :: result

  @doc "Transcription. OpenAI `/audio/transcriptions` shaped."
  @callback transcribe(params, Context.t()) :: result

  @optional_callbacks chat: 2, stream: 4, embed: 2, rerank: 2, speech: 2, transcribe: 2

  @capabilities [:chat, :stream, :embed, :rerank, :speech, :transcribe]

  @doc "The capability callbacks an adapter may implement."
  def capabilities, do: @capabilities

  @doc """
  Whether `module` implements `capability`. `stream` is arity 3; the rest are
  arity 2.
  """
  def supports?(module, capability) when capability in @capabilities do
    Code.ensure_loaded?(module) and
      function_exported?(module, capability, arity_for(capability))
  end

  defp arity_for(:stream), do: 4
  defp arity_for(_), do: 2
end
