defmodule AiroWeb.OpenAIError do
  @moduledoc """
  Builds OpenAI-shaped error envelopes so clients (and their SDKs) parse our
  failures the same way they parse OpenAI's:

      {"error": {"message": ..., "type": ..., "code": ...}}

  Used by the client-key auth plug and the chat controller.
  """

  @doc "Build the error body map. `code` is optional (nullable per OpenAI)."
  @spec body(String.t(), String.t(), String.t() | nil) :: map()
  def body(message, type, code \\ nil) do
    %{"error" => %{"message" => message, "type" => type, "code" => code}}
  end
end
