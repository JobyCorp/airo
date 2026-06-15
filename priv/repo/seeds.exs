# Script for populating the database. Run with:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: seeds one local, keyless vLLM-style provider end-to-end
# (provider → chat deployment → `chat-standard` alias) plus a dev client key.
# Safe to re-run — existing rows are reused by their unique name.

alias Airo.Config

# --- Provider: a keyless local OpenAI-compatible upstream ----------------------
provider =
  Config.get_provider_by_name("local-vllm") ||
    (
      {:ok, p} =
        Config.create_provider(%{
          name: "local-vllm",
          adapter_type: :vllm,
          base_url: "http://localhost:8000/v1",
          auth_kind: :none,
          enabled: true
        })

      p
    )

# --- Deployment: a concrete (provider, model) for chat -------------------------
deployment =
  Enum.find(
    Config.list_deployments(),
    &(&1.provider_id == provider.id and &1.capability == :chat)
  ) ||
    (
      {:ok, d} =
        Config.create_deployment(%{
          provider_id: provider.id,
          model_name: "qwen3.5-9b",
          capability: :chat,
          class: :standard,
          tool_use: true,
          context_window: 32_768,
          price_input: Decimal.new("0"),
          price_output: Decimal.new("0")
        })

      d
    )

# --- Alias: the logical handle consumers call, pinned to the one deployment ----
unless Config.get_alias_by_name("chat-standard") do
  {:ok, _alias} =
    Config.create_alias(%{
      name: "chat-standard",
      capability: :chat,
      strategy: :priority,
      candidates: [%{deployment_id: deployment.id, weight: 100, priority: 0}]
    })
end

# --- Client key: a dev consumer scoped to all aliases --------------------------
case Config.list_client_keys() |> Enum.find(&(&1.name == "dev")) do
  nil ->
    {:ok, key} = Config.mint_client_key(%{name: "dev", allowed_aliases: ["*"]})
    IO.puts("Seeded dev client key (store it — shown once): #{key.key}")

  _existing ->
    IO.puts("Dev client key already present; leaving it untouched.")
end
