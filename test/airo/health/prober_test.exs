defmodule Airo.Health.ProberTest do
  use Airo.DataCase, async: true

  import Ecto.Query

  alias Airo.Config
  alias Airo.Health
  alias Airo.Health.HealthEvent
  alias Airo.Repo
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
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "m1",
        capabilities: [:chat]
      })

    {:ok, d2} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "m2",
        capabilities: [:embeddings]
      })

    {provider, [d1, d2]}
  end

  test "a reachable provider marks all its deployments :up" do
    {provider, [d1, d2]} = provider_with_deployments()
    Req.Test.stub(Airo.TestStub, fn conn -> Req.Test.json(conn, %{"data" => []}) end)

    assert Prober.probe_provider(provider) == :up
    assert Health.status(d1.id) == :up
    assert Health.status(d2.id) == :up

    assert Repo.get_by(HealthEvent, deployment_id: d1.id, status: :up, source: :probe)
  end

  test "a 5xx provider marks its deployments :down" do
    {provider, [d1, _d2]} = provider_with_deployments()

    Req.Test.stub(Airo.TestStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
    end)

    assert Prober.probe_provider(provider) == :down
    assert Health.status(d1.id) == :down

    assert %HealthEvent{reason: "http_500"} =
             Repo.get_by(HealthEvent, deployment_id: d1.id, status: :down, source: :probe)
  end

  test "records health events only on transitions" do
    {provider, [d1, _d2]} = provider_with_deployments()
    Req.Test.stub(Airo.TestStub, fn conn -> Req.Test.json(conn, %{"data" => []}) end)

    assert Prober.probe_provider(provider) == :up
    assert Prober.probe_provider(provider) == :up

    assert [_event] =
             Repo.all(
               from e in HealthEvent,
                 where: e.deployment_id == ^d1.id and e.status == :up and e.source == :probe
             )
  end

  test "an unreachable provider marks its deployments :down" do
    {provider, [d1, _d2]} = provider_with_deployments()
    Req.Test.stub(Airo.TestStub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert Prober.probe_provider(provider) == :down
    assert Health.status(d1.id) == :down
  end

  test "a provider whose base_url makes the transport raise is :down, not a crash" do
    {provider, [d1, _d2]} = provider_with_deployments()
    # A scheme-less base_url makes Finch raise rather than return an error tuple.
    # The changeset rejects this, so reach past it to plant the bad value.
    Repo.update_all(
      from(p in Config.Provider, where: p.id == ^provider.id),
      set: [base_url: "localhost:4000"]
    )

    provider = Repo.get!(Config.Provider, provider.id)

    assert Prober.probe_provider(provider) == :down
    assert Health.status(d1.id) == :down

    assert %HealthEvent{reason: "transport_invalid_request"} =
             Repo.get_by(HealthEvent, deployment_id: d1.id, status: :down, source: :probe)
  end
end
