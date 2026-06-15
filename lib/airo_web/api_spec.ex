defmodule AiroWeb.ApiSpec do
  @moduledoc """
  The OpenAPI 3 description of Airo's gateway surface (DESIGN §5), served at
  `GET /openapi`. Operation-level detail is intentionally light — the wire is
  OpenAI-compatible, so clients use their existing SDKs; this documents the
  available paths, auth, and shapes-at-a-glance.
  """
  alias OpenApiSpex.{
    Components,
    Info,
    OpenApi,
    Operation,
    PathItem,
    Response,
    SecurityScheme,
    Server
  }

  @spec spec() :: OpenApi.t()
  def spec do
    %OpenApi{
      openapi: "3.0.0",
      info: %Info{
        title: "Airo Gateway",
        version: "1.0.0",
        description: "OpenAI-compatible gateway over a distributed model backend."
      },
      servers: [%Server{url: "/"}],
      paths: paths(),
      components: %Components{
        securitySchemes: %{
          "clientKey" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "Airo client key"
          }
        }
      },
      security: [%{"clientKey" => []}]
    }
  end

  defp paths do
    %{
      "/v1/chat/completions" =>
        post(
          "createChatCompletion",
          "Create a chat completion",
          "OpenAI-compatible; `stream: true` returns SSE."
        ),
      "/v1/embeddings" => post("createEmbedding", "Create embeddings", "OpenAI-compatible."),
      "/v1/rerank" => post("rerank", "Rerank documents", "Jina/Cohere-compatible shape."),
      "/v1/audio/speech" => post("createSpeech", "Text to speech", "Returns binary audio."),
      "/v1/audio/transcriptions" =>
        post("createTranscription", "Transcribe audio", "multipart/form-data upload."),
      "/v1/models" => get("listModels", "List available models")
    }
  end

  defp post(operation_id, summary, description) do
    %PathItem{post: operation(operation_id, summary, description)}
  end

  defp get(operation_id, summary) do
    %PathItem{get: operation(operation_id, summary, nil)}
  end

  defp operation(operation_id, summary, description) do
    %Operation{
      operationId: operation_id,
      summary: summary,
      description: description,
      responses: %{"200" => %Response{description: "Success"}}
    }
  end
end
