defmodule Airo.Usage do
  @moduledoc """
  Usage + cost attribution (DESIGN §10). One `UsageRecord` per gateway call,
  written **off the response path** via `Airo.Usage.TaskSupervisor` so recording
  never blocks the client. Cost is derived from the served deployment's pricing
  (`price_input`/`price_output`, per 1k tokens).
  """
  import Ecto.Query, warn: false

  alias Airo.Repo
  alias Airo.Usage.UsageRecord

  @task_supervisor Airo.Usage.TaskSupervisor

  @doc "List recent usage records, newest first."
  def list_usage_records(limit \\ 100) do
    UsageRecord
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Persist a single usage record synchronously."
  def record_usage(attrs) do
    %UsageRecord{} |> UsageRecord.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Record usage asynchronously from a call context map. Returns immediately;
  the record is built (tokens, finish reason, cost) and inserted in a task.

  Context keys: `:client_key`, `:served` (a `Airo.Gateway.attempt` or nil),
  `:alias_name`, `:capability`, `:response` (OpenAI body or nil), `:latency_ms`,
  `:outcome`, `:fallback_used`.
  """
  def record_async(context) do
    if async?() do
      Task.Supervisor.start_child(@task_supervisor, fn ->
        context |> build_attrs() |> record_usage()
      end)
    else
      context |> build_attrs() |> record_usage()
    end

    :ok
  end

  # Synchronous in test (so the SQL sandbox connection is available); async in
  # dev/prod so recording never blocks the response.
  defp async?, do: Application.get_env(:airo, __MODULE__, [])[:async] != false

  @doc """
  Build `UsageRecord` attrs from a call context — extracts token counts and
  finish reason from the OpenAI response and computes cost from the served
  deployment's pricing. Exposed for testing; normally called via `record_async/1`.
  """
  def build_attrs(context) do
    {tokens_in, tokens_out} = tokens(context[:response])
    deployment = context[:served] && context[:served].deployment

    %{
      client_key_id: context[:client_key] && context[:client_key].id,
      deployment_id: deployment && deployment.id,
      alias_name: context[:alias_name],
      capability: context[:capability],
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      latency_ms: context[:latency_ms],
      outcome: context[:outcome] || :success,
      finish_reason: finish_reason(context[:response]),
      fallback_used: context[:fallback_used] || false,
      cost: cost(deployment, tokens_in, tokens_out)
    }
  end

  @doc "Total cost across the recorded usage (Decimal)."
  def total_cost do
    Repo.one(from r in UsageRecord, select: coalesce(sum(r.cost), 0))
  end

  ## Internal

  defp tokens(%{"usage" => usage}) when is_map(usage),
    do: {usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0}

  defp tokens(_response), do: {0, 0}

  defp finish_reason(%{"choices" => [%{"finish_reason" => reason} | _]}), do: reason
  defp finish_reason(_response), do: nil

  defp cost(nil, _tokens_in, _tokens_out), do: nil
  defp cost(%{price_input: nil, price_output: nil}, _tokens_in, _tokens_out), do: nil

  defp cost(%{price_input: price_in, price_output: price_out}, tokens_in, tokens_out),
    do: Decimal.add(per_1k(price_in, tokens_in), per_1k(price_out, tokens_out))

  defp per_1k(nil, _tokens), do: Decimal.new(0)

  defp per_1k(price, tokens),
    do: Decimal.mult(price, Decimal.div(Decimal.new(tokens || 0), 1000))
end
