defmodule Airo.Health.ProberTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Health
  alias Airo.Health.Prober

  defp provider_with_deployments do
    {:ok, provider} =
      Config.create_provider(%{
        name: "p-#{System.unique_integer([:positive])}",
        adapter_type: :vllm,
        base_url: "http://upstream:8000/v1",
        auth_kind: :none
      })

    {:ok, d1} =
      Config.create_deployment(%{provider_id: provider.id, model_name: "m1", capability: :chat})

    {:ok, d2} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "m2",
        capability: :embeddings
      })

    {provider, [d1, d2]}
  end

  test "a reachable provider marks all its deployments :up" do
    {provider, [d1, d2]} = provider_with_deployments()
    Req.Test.stub(Airo.TestStub, fn conn -> Req.Test.json(conn, %{"data" => []}) end)

    assert Prober.probe_provider(provider) == :up
    assert Health.status(d1.id) == :up
    assert Health.status(d2.id) == :up
  end

  test "a 5xx provider marks its deployments :down" do
    {provider, [d1, _d2]} = provider_with_deployments()

    Req.Test.stub(Airo.TestStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
    end)

    assert Prober.probe_provider(provider) == :down
    assert Health.status(d1.id) == :down
  end

  test "an unreachable provider marks its deployments :down" do
    {provider, [d1, _d2]} = provider_with_deployments()
    Req.Test.stub(Airo.TestStub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert Prober.probe_provider(provider) == :down
    assert Health.status(d1.id) == :down
  end
end
