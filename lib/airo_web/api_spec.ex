defmodule AiroWeb.ApiSpec do
  @moduledoc """
  The OpenAPI 3 description of Airo's gateway surface (DESIGN §5), served at
  `GET /openapi` and rendered as Swagger UI at `/docs`.

  The wire is OpenAI-compatible, so clients use their existing SDKs; the schemas
  here document the request/response shapes plus Airo's additions — the `route`
  object (class/tools/vision routing), the `:classify` capability, and the
  `capabilities` array on `/v1/models`. Request bodies allow extra properties
  (`additionalProperties: true`) so OpenAI passthrough fields (temperature,
  max_tokens, tools, …) are accepted without being enumerated here.
  """
  alias OpenApiSpex.{
    Components,
    Info,
    MediaType,
    OpenApi,
    Operation,
    Parameter,
    PathItem,
    Reference,
    RequestBody,
    Response,
    Schema,
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
        description:
          "OpenAI-compatible gateway over a distributed model backend. " <>
            "Authenticate with a client key as a Bearer token."
      },
      servers: [%Server{url: "/"}],
      paths: paths(),
      components: %Components{
        schemas: schemas(),
        securitySchemes: %{
          "clientKey" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "Airo client key (minted under /admin/keys)."
          }
        }
      },
      security: [%{"clientKey" => []}]
    }
  end

  ## Paths

  defp paths do
    %{
      "/v1/chat/completions" => %PathItem{
        post:
          op(
            "createChatCompletion",
            "Create a chat completion",
            "OpenAI-compatible. `stream: true` returns SSE. Image content in " <>
              "`messages` auto-routes to a vision-capable deployment.",
            req("ChatCompletionRequest"),
            resp(
              "ChatCompletionResponse",
              "Chat completion (or an SSE stream when `stream: true`)."
            )
          )
      },
      "/v1/embeddings" => %PathItem{
        post:
          op(
            "createEmbedding",
            "Create embeddings",
            "OpenAI-compatible.",
            req("EmbeddingRequest"),
            resp("EmbeddingResponse", "Embedding vectors.")
          )
      },
      "/v1/rerank" => %PathItem{
        post:
          op(
            "rerank",
            "Rerank documents",
            "Jina/Cohere-compatible shape.",
            req("RerankRequest"),
            resp("RerankResponse", "Documents scored by relevance.")
          )
      },
      "/v1/classify" => %PathItem{
        post:
          op(
            "classify",
            "Classify / score text",
            "Infinity-compatible shape: `{model, input}` → scored labels per input.",
            req("ClassifyRequest"),
            resp("ClassifyResponse", "Per-input label scores.")
          )
      },
      "/v1/audio/speech" => %PathItem{
        post:
          op(
            "createSpeech",
            "Text to speech",
            "Returns binary audio.",
            req("SpeechRequest"),
            %Response{
              description: "Binary audio.",
              content: %{
                "audio/mpeg" => %MediaType{schema: %Schema{type: :string, format: :binary}}
              }
            }
          )
      },
      "/v1/audio/transcriptions" => %PathItem{
        post:
          op(
            "createTranscription",
            "Transcribe audio",
            "`multipart/form-data` upload (`file` + `model`).",
            %RequestBody{
              required: true,
              content: %{
                "multipart/form-data" => %MediaType{
                  schema: %Schema{
                    type: :object,
                    required: [:file, :model],
                    properties: %{
                      file: %Schema{type: :string, format: :binary, description: "Audio file."},
                      model: %Schema{type: :string, description: "Alias or concrete model id."}
                    }
                  }
                }
              }
            },
            resp("TranscriptionResponse", "Transcribed text.")
          )
      },
      "/v1/models" => %PathItem{
        get: %Operation{
          operationId: "listModels",
          summary: "List available models",
          description:
            "Aliases + concrete deployment ids the client key can call. Each entry " <>
              "carries a `capabilities` array so you know which endpoint it serves.",
          responses:
            Map.merge(error_responses(), %{
              "200" => resp("ModelList", "The callable models for this key.")
            })
        }
      },
      "/v1/serving" => %PathItem{
        get:
          management_op(
            "getServing",
            "Serving topology",
            "Which host serves what: agent hosts with their GPU telemetry and " <>
              "slots, each slot's resident model, every deployment's health and " <>
              "routability, external providers, and alias resolution. " <>
              "`ETag`/`If-None-Match` supported — a poller gets `304` while " <>
              "topology is unchanged.",
            [
              param(
                "inventory",
                "Also call each host agent for the models it holds on disk, and " <>
                  "use their sizes for per-slot capacity math. One outbound HTTP " <>
                  "call per host, so off by default.",
                %Schema{type: :boolean, default: false}
              )
            ],
            resp("ServingSnapshot", "The current serving topology.")
          )
      },
      "/v1/serving/health" => %PathItem{
        get:
          management_op(
            "getServingHealth",
            "Health transitions",
            "Deployment health *changes*, so a consumer records flaps rather " <>
              "than sampling current state and missing what happened between " <>
              "polls. Each event carries `previous_status`, `duration_ms` and " <>
              "`changed` (false for the duplicate `up` row an Airo restart " <>
              "writes — count flaps on `changed`).",
            [since_param(), limit_param()],
            resp("HealthTransitions", "Health transitions, oldest first.")
          )
      },
      "/v1/usage" => %PathItem{
        get:
          management_op(
            "getUsage",
            "Token and cost attribution",
            "Usage rolled up along one axis. `next_since` is the id of the " <>
              "newest record counted, so consecutive polls partition the record " <>
              "stream exactly — no double-counting, no gap at the boundary.",
            [
              since_param(),
              limit_param(),
              param(
                "group_by",
                "Attribution axis.",
                %Schema{
                  type: :string,
                  enum: ~w(deployment model alias capability client_key),
                  default: "deployment"
                }
              )
            ],
            resp("UsageRollup", "Usage rolled up along the requested axis.")
          )
      },
      "/metrics" => %PathItem{
        get: %Operation{
          operationId: "getMetrics",
          summary: "Prometheus metrics",
          description:
            "The serving topology in Prometheus exposition format. Scrape with " <>
              "the management client key as a bearer token. `airo_slot_status` " <>
              "and `airo_deployment_health` use the enum idiom (one series per " <>
              "state, one of them `1`), so alert on `status=\"down\"` being 1 " <>
              "rather than on a series being absent.",
          responses:
            Map.merge(management_errors(), %{
              "200" => %Response{
                description: "Prometheus text exposition.",
                content: %{
                  "text/plain" => %MediaType{schema: %Schema{type: :string}}
                }
              }
            })
        }
      }
    }
  end

  ## Management surface

  defp management_op(operation_id, summary, description, parameters, success) do
    %Operation{
      operationId: operation_id,
      summary: summary,
      description: description,
      parameters: parameters,
      responses: Map.merge(management_errors(), %{"200" => success})
    }
  end

  defp management_errors do
    %{
      "401" => resp("Error", "Missing or invalid client key."),
      "403" => resp("Error", "The client key is not scoped for management access.")
    }
  end

  defp since_param do
    param(
      "since",
      "Cursor. An event/record **id** (exact — use the `next_since` from the " <>
        "previous response) or an ISO 8601 timestamp (convenient, but drops " <>
        "rows sharing the boundary second). Omit for everything.",
      %Schema{type: :string}
    )
  end

  defp limit_param,
    do: param("limit", "Maximum rows.", %Schema{type: :integer, default: 500, maximum: 5_000})

  defp param(name, description, schema) do
    %Parameter{
      name: String.to_atom(name),
      in: :query,
      required: false,
      description: description,
      schema: schema
    }
  end

  ## Operation + response helpers

  defp op(operation_id, summary, description, request_body, success) do
    %Operation{
      operationId: operation_id,
      summary: summary,
      description: description,
      requestBody: request_body,
      responses: Map.merge(error_responses(), %{"200" => success})
    }
  end

  defp req(schema_name) do
    %RequestBody{
      required: true,
      content: %{"application/json" => %MediaType{schema: ref(schema_name)}}
    }
  end

  defp resp(schema_name, description) do
    %Response{
      description: description,
      content: %{"application/json" => %MediaType{schema: ref(schema_name)}}
    }
  end

  defp error_responses do
    %{
      "401" => resp("Error", "Missing or invalid client key."),
      "404" => resp("Error", "No matching model/deployment for the requested capability.")
    }
  end

  defp ref(name), do: %Reference{"$ref": "#/components/schemas/#{name}"}

  ## Schemas

  defp schemas do
    %{
      "Route" => %Schema{
        type: :object,
        description: "Optional Airo routing controls, sent alongside the request body.",
        properties: %{
          class: %Schema{
            type: :string,
            enum: ["edge", "standard", "deep", "cloud"],
            description: "Prefer deployments of this class."
          },
          tools: %Schema{type: :boolean, description: "Require tool-use-capable deployments."},
          vision: %Schema{
            type: :boolean,
            description: "Force/skip vision routing (auto-detected from image content otherwise)."
          },
          binding: %Schema{
            type: :string,
            description: "Strict pin to `adapter:model` or `provider:model`."
          },
          fallback: %Schema{
            type: :array,
            items: %Schema{type: :string},
            description: "Fallback alias names."
          }
        }
      },
      "ChatMessage" => %Schema{
        type: :object,
        required: [:role],
        properties: %{
          role: %Schema{type: :string, enum: ["system", "user", "assistant", "tool"]},
          content: %Schema{
            description:
              "Plain text, or an array of OpenAI content parts (`text` / `image_url`) for vision.",
            oneOf: [
              %Schema{type: :string},
              %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}}
            ]
          }
        }
      },
      "ChatCompletionRequest" => %Schema{
        type: :object,
        required: [:model, :messages],
        additionalProperties: true,
        properties: %{
          model: %Schema{
            type: :string,
            description: "Alias (e.g. `chat-deep`) or concrete deployment id."
          },
          messages: %Schema{type: :array, items: ref("ChatMessage")},
          stream: %Schema{
            type: :boolean,
            default: false,
            description: "Stream the response as SSE."
          },
          route: ref("Route")
        },
        example: %{
          "model" => "chat-deep",
          "messages" => [%{"role" => "user", "content" => "Hello!"}],
          "route" => %{"class" => "deep"}
        }
      },
      "ChatCompletionResponse" => %Schema{
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          object: %Schema{type: :string, example: "chat.completion"},
          created: %Schema{type: :integer},
          model: %Schema{type: :string},
          choices: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                index: %Schema{type: :integer},
                message: ref("ChatMessage"),
                finish_reason: %Schema{type: :string}
              }
            }
          },
          usage: ref("Usage")
        }
      },
      "EmbeddingRequest" => %Schema{
        type: :object,
        required: [:model, :input],
        additionalProperties: true,
        properties: %{
          model: %Schema{type: :string},
          input: %Schema{
            description: "A string or array of strings to embed.",
            oneOf: [%Schema{type: :string}, %Schema{type: :array, items: %Schema{type: :string}}]
          },
          route: ref("Route")
        },
        example: %{"model" => "embed-fast", "input" => "hello world"}
      },
      "EmbeddingResponse" => %Schema{
        type: :object,
        properties: %{
          object: %Schema{type: :string, example: "list"},
          model: %Schema{type: :string},
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                object: %Schema{type: :string, example: "embedding"},
                index: %Schema{type: :integer},
                embedding: %Schema{type: :array, items: %Schema{type: :number}}
              }
            }
          },
          usage: ref("Usage")
        }
      },
      "RerankRequest" => %Schema{
        type: :object,
        required: [:model, :query, :documents],
        additionalProperties: true,
        properties: %{
          model: %Schema{type: :string},
          query: %Schema{type: :string},
          documents: %Schema{type: :array, items: %Schema{type: :string}},
          top_n: %Schema{type: :integer, description: "Return only the top N results."},
          route: ref("Route")
        },
        example: %{
          "model" => "rerank",
          "query" => "capital of France",
          "documents" => ["Paris", "Berlin"]
        }
      },
      "RerankResponse" => %Schema{
        type: :object,
        properties: %{
          results: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                index: %Schema{type: :integer},
                relevance_score: %Schema{type: :number}
              }
            }
          }
        }
      },
      "ClassifyRequest" => %Schema{
        type: :object,
        required: [:model, :input],
        additionalProperties: true,
        properties: %{
          model: %Schema{type: :string},
          input: %Schema{
            type: :array,
            items: %Schema{type: :string},
            description: "Texts to classify."
          },
          route: ref("Route")
        },
        example: %{"model" => "classify", "input" => ["I am not having a great day."]}
      },
      "ClassifyResponse" => %Schema{
        type: :object,
        properties: %{
          object: %Schema{type: :string, example: "classify"},
          model: %Schema{type: :string},
          data: %Schema{
            type: :array,
            description: "One array of scored labels per input, highest score first.",
            items: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  label: %Schema{type: :string},
                  score: %Schema{type: :number}
                }
              }
            }
          },
          usage: ref("Usage")
        }
      },
      "SpeechRequest" => %Schema{
        type: :object,
        required: [:model, :input],
        additionalProperties: true,
        properties: %{
          model: %Schema{type: :string},
          input: %Schema{type: :string, description: "Text to synthesize."},
          voice: %Schema{type: :string},
          route: ref("Route")
        },
        example: %{"model" => "tts", "input" => "Hello there", "voice" => "af_heart"}
      },
      "TranscriptionResponse" => %Schema{
        type: :object,
        properties: %{text: %Schema{type: :string}}
      },
      "ModelList" => %Schema{
        type: :object,
        properties: %{
          object: %Schema{type: :string, example: "list"},
          data: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string},
                object: %Schema{type: :string, example: "model"},
                owned_by: %Schema{type: :string, example: "airo"},
                capabilities: %Schema{
                  type: :array,
                  items: %Schema{
                    type: :string,
                    enum: [
                      "chat",
                      "embeddings",
                      "rerank",
                      "speech",
                      "transcription",
                      "vision",
                      "classify"
                    ]
                  },
                  description: "Which endpoints this id serves."
                },
                context_length: %Schema{
                  type: :integer,
                  nullable: true,
                  description:
                    "Smallest known context window among the enabled deployments " <>
                      "serving this id (aliases: their own candidates, fallbacks " <>
                      "excluded). Null when no serving copy declares one. Size " <>
                      "prompts and compaction against this."
                }
              }
            }
          }
        }
      },
      "Usage" => %Schema{
        type: :object,
        properties: %{
          prompt_tokens: %Schema{type: :integer},
          completion_tokens: %Schema{type: :integer},
          total_tokens: %Schema{type: :integer}
        }
      },
      "Error" => %Schema{
        type: :object,
        description: "OpenAI-shaped error envelope.",
        properties: %{
          error: %Schema{
            type: :object,
            properties: %{
              message: %Schema{type: :string},
              type: %Schema{type: :string},
              code: %Schema{type: :string}
            }
          }
        }
      }
    }
    |> Map.merge(management_schemas())
  end

  # The management payloads are wide and mostly self-describing; these document
  # the fields a consumer can't guess the semantics of, and leave the rest open
  # rather than pinning an exhaustive shape that would drift from the code.
  defp management_schemas do
    %{
      "ServingSnapshot" => %Schema{
        type: :object,
        description:
          "Serving topology. Note two things the payload makes explicit because " <>
            "they are easy to get wrong: health decays to `unknown` once a " <>
            "snapshot is older than `staleness_ms` (so read `stale`/`age_ms`, " <>
            "not `status` alone), and health is a *preference* in Airo, not a " <>
            "gate — `eligible` is the hard config gate, `routable` is eligible " <>
            "**and** healthy, and an eligible-but-unhealthy deployment is still " <>
            "tried as a last resort.",
        properties: %{
          generated_at: %Schema{type: :string, format: :"date-time"},
          staleness_ms: %Schema{
            type: :integer,
            description: "Age at which a health snapshot decays to `unknown`."
          },
          hosts: %Schema{
            type: :array,
            description:
              "Agent-managed hosts. Each slot holds at most one resident model; " <>
                "`resident` is null when the slot is empty. Join a resident " <>
                "model on `upstream_model_id` — the agent's `model` id is the " <>
                "real artifact name and is not unique across hosts.",
            items: %Schema{type: :object, additionalProperties: true}
          },
          external_providers: %Schema{
            type: :array,
            description: "Upstreams Airo routes to but does not manage.",
            items: %Schema{type: :object, additionalProperties: true}
          },
          clusters: %Schema{
            type: :array,
            description:
              "Multi-node (tensor-parallel) loads, joined back into one logical " <>
                "entry. A model too large for one host runs as several slots on " <>
                "different hosts sharing a cluster id; only rank 0 serves the " <>
                "API (`serves_api`), the rest hold a shard of the weights. " <>
                "`complete` compares reporting ranks against the declared " <>
                "`tp_size` — a rank that goes silent leaves no slot behind, so " <>
                "absence is the failure mode, not a `down` status. Alert on " <>
                "`serving`, since losing any rank takes the whole load down " <>
                "while the head's own slot still reads `up`.",
            items: %Schema{type: :object, additionalProperties: true}
          },
          aliases: %Schema{
            type: :array,
            description:
              "Alias resolution. `servable` tracks the hard gate (at least one " <>
                "eligible candidate); `routable_candidates` counts the healthy ones.",
            items: %Schema{type: :object, additionalProperties: true}
          }
        }
      },
      "HealthTransitions" => %Schema{
        type: :object,
        properties: %{
          generated_at: %Schema{type: :string, format: :"date-time"},
          events: %Schema{
            type: :array,
            items: %Schema{type: :object, additionalProperties: true}
          },
          next_since: %Schema{
            type: :integer,
            nullable: true,
            description: "Cursor for the next poll."
          },
          has_more: %Schema{
            type: :boolean,
            description: "More events beyond `limit`; poll again immediately."
          }
        }
      },
      "UsageRollup" => %Schema{
        type: :object,
        properties: %{
          generated_at: %Schema{type: :string, format: :"date-time"},
          group_by: %Schema{type: :string},
          rows: %Schema{
            type: :array,
            description:
              "One row per group, with `requests`, `errors`, `timeouts`, " <>
                "`fallbacks`, `tokens_in`, `tokens_out`, `cost`, and " <>
                "`p50_latency_ms`/`p95_latency_ms`.",
            items: %Schema{type: :object, additionalProperties: true}
          },
          next_since: %Schema{
            type: :integer,
            nullable: true,
            description: "Id of the newest record counted; pass as `since` to continue exactly."
          }
        }
      }
    }
  end
end
