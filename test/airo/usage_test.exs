defmodule Airo.UsageTest do
  # async: false so the SQL sandbox runs in shared mode and the off-path
  # Task.Supervisor process can write to the DB.
  use Airo.DataCase, async: false

  alias Airo.{Config, Usage}
  alias Airo.Config.Deployment

  @response %{
    "choices" => [%{"finish_reason" => "stop"}],
    "usage" => %{"prompt_tokens" => 1000, "completion_tokens" => 500}
  }

  describe "build_attrs/1" do
    test "extracts tokens + finish reason and computes cost from pricing" do
      deployment = %Deployment{
        id: 7,
        price_input: Decimal.new("0.002"),
        price_output: Decimal.new("0.006")
      }

      attrs =
        Usage.build_attrs(%{
          served: %{deployment: deployment},
          alias_name: "chat-deep",
          capability: :chat,
          response: @response,
          latency_ms: 42
        })

      assert attrs.tokens_in == 1000
      assert attrs.tokens_out == 500
      assert attrs.finish_reason == "stop"
      assert attrs.deployment_id == 7
      # 1000/1000 * 0.002 + 500/1000 * 0.006 = 0.002 + 0.003 = 0.005
      assert Decimal.equal?(attrs.cost, Decimal.new("0.005"))
    end

    test "cost is nil when the deployment has no pricing" do
      attrs =
        Usage.build_attrs(%{
          served: %{deployment: %Deployment{id: 1}},
          capability: :chat,
          response: @response
        })

      assert attrs.cost == nil
    end

    test "tokens default to zero without a usage block" do
      attrs = Usage.build_attrs(%{capability: :speech, response: nil})
      assert {attrs.tokens_in, attrs.tokens_out} == {0, 0}
      assert attrs.deployment_id == nil
    end
  end

  describe "record_async/1" do
    test "writes a usage record off the response path" do
      {:ok, provider} =
        Config.create_provider(%{
          name: "p",
          adapter_type: :vllm,
          base_url: "http://p/v1",
          auth_kind: :none
        })

      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: provider.id,
          model_name: "m",
          capabilities: [:chat],
          price_input: Decimal.new("0.001"),
          price_output: Decimal.new("0.002")
        })

      {:ok, key} = Config.mint_client_key(%{name: "k", allowed_aliases: ["*"]})

      :ok =
        Usage.record_async(%{
          client_key: key,
          served: %{deployment: deployment},
          alias_name: "chat-standard",
          capability: :chat,
          response: @response,
          latency_ms: 10
        })

      record = eventually(fn -> List.first(Usage.list_usage_records()) end)
      assert record.alias_name == "chat-standard"
      assert record.tokens_in == 1000
      assert record.deployment_id == deployment.id
      assert record.model_id == deployment.model_id
      assert record.model_display_name == "m"
      assert record.model_upstream_id == "m"
      assert Decimal.equal?(record.cost, Decimal.new("0.002"))
    end

    test "snapshots model version metadata at usage-write time" do
      {:ok, provider} =
        Config.create_provider(%{
          name: "version-host",
          adapter_type: :vllm,
          base_url: "http://p/v1",
          auth_kind: :none
        })

      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: provider.id,
          model_name: "qwen-eval",
          capabilities: [:chat]
        })

      model = Config.get_model!(deployment.model_id)
      {:ok, model} = Config.update_model(model, %{version: "v1", revision: "r1"})

      :ok =
        Usage.record_async(%{
          served: %{deployment: %{deployment | model: model}},
          alias_name: "chat-eval",
          capability: :chat,
          response: @response
        })

      {:ok, model} = Config.update_model(model, %{version: "v2", revision: "r2"})

      :ok =
        Usage.record_async(%{
          served: %{deployment: %{deployment | model: model}},
          alias_name: "chat-eval",
          capability: :chat,
          response: @response
        })

      records =
        eventually(fn ->
          records = Usage.list_usage_records(%{"model" => "qwen-eval"}, 10)
          if length(records) == 2, do: records
        end)

      assert records |> Enum.map(& &1.model_version) |> Enum.sort() == ["v1", "v2"]
      assert records |> Enum.map(& &1.model_revision) |> Enum.sort() == ["r1", "r2"]
    end
  end

  describe "performance_series/1" do
    test "returns fixed chart buckets for recent usage" do
      {:ok, _} =
        Usage.record_usage(%{
          trace_id: "gt_success",
          capability: :chat,
          outcome: :success,
          latency_ms: 10,
          fallback_used: false
        })

      {:ok, _} =
        Usage.record_usage(%{
          trace_id: "gt_error",
          capability: :chat,
          outcome: :error,
          latency_ms: 30,
          fallback_used: true
        })

      series = Usage.performance_series(%{"range" => "24h"})

      assert length(series.categories) == 24
      assert Enum.sum(series.requests) == 2
      assert Enum.sum(series.errors) == 1
      assert Enum.sum(series.fallbacks) == 1
      assert 30 in series.p95_latency_ms
    end

    test "a bucket with no calls reports zero requests and no latency" do
      # Absent is not zero for a percentile: "nothing was served in this five
      # minutes" must not render as "0 ms". Only the counts fill with 0.
      series = Usage.performance_series(%{"range" => "1h"})

      assert length(series.categories) == 12
      assert series.requests == List.duplicate(0, 12)
      assert series.errors == List.duplicate(0, 12)
      assert series.p50_latency_ms == List.duplicate(nil, 12)
      assert series.p95_latency_ms == List.duplicate(nil, 12)
    end

    test "rows land in the bucket their age puts them in" do
      # The aggregation moved into SQL; this pins that the bucket maths didn't
      # move with it. 1h => twelve 5-minute buckets, newest last.
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      for {minutes_ago, latency} <- [{2, 11}, {32, 22}] do
        {:ok, record} =
          Usage.record_usage(%{
            trace_id: "gt_bucket_#{minutes_ago}",
            capability: :chat,
            outcome: :success,
            latency_ms: latency
          })

        Airo.Repo.update_all(
          from(r in Airo.Usage.UsageRecord, where: r.id == ^record.id),
          set: [inserted_at: NaiveDateTime.add(now, -minutes_ago * 60, :second)]
        )
      end

      series = Usage.performance_series(%{"range" => "1h"})

      # ~2 min old => last bucket; ~32 min old => middle of the window.
      assert List.last(series.requests) == 1
      assert List.last(series.p95_latency_ms) == 11
      assert Enum.sum(series.requests) == 2
      assert 22 in series.p95_latency_ms
    end
  end

  describe "usage_summary/1" do
    test "counts outcomes and picks an observed latency for each percentile" do
      # percentile_disc, not _cont: p50/p95 must be a latency that actually
      # happened, matching what the pre-SQL implementation reported.
      for {outcome, latency} <- [{:success, 10}, {:success, 20}, {:error, 30}, {:success, 40}] do
        {:ok, _} =
          Usage.record_usage(%{
            trace_id: "gt_pct_#{outcome}_#{latency}",
            capability: :chat,
            outcome: outcome,
            latency_ms: latency
          })
      end

      summary = Usage.usage_summary(%{"range" => "24h"})

      assert summary.total == 4
      assert summary.errors == 1
      assert summary.error_rate == "25.0%"
      assert summary.p50_latency_ms in [10, 20, 30, 40]
      assert summary.p95_latency_ms == 40
    end

    test "an empty window reports zeroes rather than dividing by zero" do
      summary = Usage.usage_summary(%{"range" => "1h"})

      assert summary.total == 0
      assert summary.errors == 0
      assert summary.error_rate == "0.0%"
      assert summary.p50_latency_ms == nil
      assert Decimal.equal?(summary.total_cost, Decimal.new(0))
    end

    test "records with no latency don't drag the percentiles down" do
      # nil latency was rejected before aggregating; the ordered-set aggregate
      # ignores NULLs, which is the same thing — assert it, don't assume it.
      {:ok, _} =
        Usage.record_usage(%{trace_id: "gt_nil_lat", capability: :chat, outcome: :success})

      {:ok, _} =
        Usage.record_usage(%{
          trace_id: "gt_real_lat",
          capability: :chat,
          outcome: :success,
          latency_ms: 500
        })

      summary = Usage.usage_summary(%{"range" => "24h"})

      assert summary.total == 2
      assert summary.p50_latency_ms == 500
      assert summary.p95_latency_ms == 500
    end
  end

  defp eventually(fun, retries \\ 50) do
    case fun.() do
      nil when retries > 0 -> Process.sleep(10) && eventually(fun, retries - 1)
      result -> result
    end
  end
end
