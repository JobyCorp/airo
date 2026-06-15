defmodule Airo.ModelsTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Models

  defp provider(attrs \\ %{}) do
    {:ok, provider} =
      Config.create_provider(
        Map.merge(
          %{name: "local-vllm", adapter_type: :vllm, base_url: "http://localhost:8000/v1"},
          attrs
        )
      )

    provider
  end

  describe "list/1" do
    test "returns the ids the provider's upstream catalog advertises" do
      Req.Test.stub(Airo.TestStub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/models"

        Req.Test.json(conn, %{
          "data" => [%{"id" => "qwen3.5-9b"}, %{"id" => "nomic-embed"}]
        })
      end)

      assert {:ok, ["qwen3.5-9b", "nomic-embed"]} = Models.list(provider())
    end

    test "returns an error when the upstream is unreachable" do
      Req.Test.stub(Airo.TestStub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transport_error, _}} = Models.list(provider())
    end
  end
end
