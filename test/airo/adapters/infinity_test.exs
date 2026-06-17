defmodule Airo.Adapters.InfinityTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.Infinity
  alias Airo.Config.{Deployment, Provider}

  defp context do
    provider = %Provider{
      name: "inf",
      adapter_type: :infinity,
      base_url: "http://inf:7997",
      auth_kind: :none
    }

    Context.new(provider,
      deployment: %Deployment{model_name: "bge-reranker"},
      opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )
  end

  defp models_payload do
    %{
      "data" => [
        %{
          "id" => "BAAI/bge-reranker-v2-m3",
          "stats" => %{
            "queue_fraction" => 0.0,
            "queue_absolute" => 0,
            "results_pending" => 0,
            "batch_size" => 32
          },
          "object" => "model",
          "owned_by" => "infinity",
          "created" => 1_781_703_287,
          "backend" => "torch",
          "capabilities" => ["rerank"]
        }
      ],
      "object" => "list"
    }
  end

  defp metrics_body do
    """
    http_requests_total{handler="/rerank",method="POST",status="2xx"} 250.0
    http_request_duration_seconds_count{handler="/rerank",method="POST"} 250.0
    http_request_duration_seconds_sum{handler="/rerank",method="POST"} 8.0
    http_requests_total{handler="/embeddings",method="POST",status="2xx"} 470.0
    """
  end

  test "rerank/2 posts to /rerank with the deployment model and returns the body" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:rerank, conn.request_path, Jason.decode!(raw)["model"]})
      Req.Test.json(conn, %{"results" => [%{"index" => 0, "relevance_score" => 0.9}]})
    end)

    assert {:ok, body} =
             Infinity.rerank(
               %{"model" => "rr", "query" => "q", "documents" => ["a", "b"]},
               context()
             )

    assert hd(body["results"])["relevance_score"] == 0.9
    assert_received {:rerank, "/rerank", "bge-reranker"}
  end

  test "classify/2 posts to /classify with the deployment model and returns the body" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:classify, conn.request_path, Jason.decode!(raw)["model"]})

      Req.Test.json(conn, %{
        "object" => "classify",
        "data" => [[%{"label" => "joy", "score" => 0.9}]]
      })
    end)

    assert {:ok, body} = Infinity.classify(%{"model" => "c", "input" => ["hi"]}, context())

    assert body["data"] |> hd() |> hd() |> Map.get("label") == "joy"
    assert_received {:classify, "/classify", "bge-reranker"}
  end

  test "embed/2 posts to /embeddings" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:path, conn.request_path})
      Req.Test.json(conn, %{"data" => [%{"embedding" => [0.1]}]})
    end)

    assert {:ok, _} = Infinity.embed(%{"model" => "e", "input" => "x"}, context())
    assert_received {:path, "/embeddings"}
  end

  test "maps a non-2xx to {:error, {:http_error, ...}}" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)

    assert {:error, {:http_error, 500, _}} =
             Infinity.rerank(%{"query" => "q", "documents" => []}, context())
  end

  test "catalog/1 uses /models and normalizes model metadata" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})
      Req.Test.json(conn, models_payload())
    end)

    assert {:ok, [model]} = Infinity.catalog(context())
    assert model.id == "BAAI/bge-reranker-v2-m3"
    assert model.family == "bge"
    assert model.type == "rerank"
    assert model.backend == "torch"
    assert model.batch_size == 32
    assert model.capabilities == ["rerank"]
    assert_received {:request, "GET", "/models"}
  end

  test "inspect_model/2 finds model metadata by id" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, models_payload())
    end)

    assert {:ok, metadata} = Infinity.inspect_model("BAAI/bge-reranker-v2-m3", context())
    assert metadata.type == "rerank"
    assert metadata.queue_absolute == 0
  end

  test "runtime_info/1 combines catalog and endpoint metrics" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/models"} = conn ->
        Req.Test.json(conn, models_payload())

      %{request_path: "/metrics"} = conn ->
        Req.Test.text(conn, metrics_body())
    end)

    assert {:ok, %{running: [running], metrics: %{"rerank" => metrics}}} =
             Infinity.runtime_info(context())

    assert running.id == "BAAI/bge-reranker-v2-m3"
    assert metrics["requests_post_2xx"] == 250.0
    assert metrics["duration_post_count"] == 250.0
    assert metrics["duration_post_seconds_sum"] == 8.0
  end
end
