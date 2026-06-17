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
      Req.Test.json(conn, %{"object" => "classify", "data" => [[%{"label" => "joy", "score" => 0.9}]]})
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
end
