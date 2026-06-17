defmodule Airo.Health.Prober do
  @moduledoc """
  Periodically probes each enabled provider and records per-deployment health in
  `Airo.Health` (DESIGN §9, §13). Probing is provider-level (one cheap `GET
  /models` per upstream); every deployment of a reachable provider is marked
  `:up`, otherwise `:down`.

  Health is a preference signal, so a probe failure never removes a deployment
  from routing — it only deprioritizes it. Configure via:

      config :airo, Airo.Health.Prober,
        enabled: true,          # disabled in test
        interval_ms: 30_000,
        probe_timeout_ms: 5_000
  """
  use GenServer

  require Logger

  alias Airo.Adapter.Context
  alias Airo.Config
  alias Airo.Repo
  alias Airo.Transport

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Probe all enabled providers once, now (used by the timer and tests)."
  def probe_now, do: GenServer.call(__MODULE__, :probe, 30_000)

  @impl true
  def init(_opts) do
    config = config()

    if config.enabled do
      send(self(), :probe)
    end

    {:ok, config}
  end

  @impl true
  def handle_info(:probe, state) do
    probe_all(state)
    Process.send_after(self(), :probe, state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:probe, _from, state) do
    {:reply, probe_all(state), state}
  end

  defp probe_all(state) do
    Config.list_providers()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(&probe_provider(&1, state.probe_timeout_ms))
  end

  @doc """
  Probe one provider and mark each of its deployments. Returns the provider
  status. A response (even 4xx) means reachable → `:up`; a 5xx or transport
  failure → `:down`.
  """
  @spec probe_provider(Airo.Config.Provider.t(), pos_integer()) :: Airo.Health.status()
  def probe_provider(provider, timeout_ms \\ 5_000) do
    provider = Repo.preload(provider, [:deployments, :credential])
    ctx = Context.new(provider, opts: [req_options: [receive_timeout: timeout_ms]])

    started = System.monotonic_time(:millisecond)
    {status, latency, reason} = classify(Transport.get(ctx, "/models"), started)

    for deployment <- provider.deployments do
      Airo.Health.mark_deployment(deployment, provider, status,
        latency_ms: latency,
        source: :probe,
        reason: reason
      )
    end

    status
  end

  defp classify({:ok, %{status: code}}, started) when code < 500,
    do: {:up, System.monotonic_time(:millisecond) - started, nil}

  defp classify({:ok, %{status: code}}, _started), do: {:down, nil, "http_#{code}"}

  defp classify({:error, reason}, _started), do: {:down, nil, reason_code(reason)}
  defp classify(_other, _started), do: {:down, nil, "probe_failed"}

  defp reason_code(%{reason: reason}), do: "transport_#{reason}"
  defp reason_code(reason) when is_atom(reason), do: "transport_#{reason}"
  defp reason_code(_reason), do: "transport_error"

  defp config do
    opts = Application.get_env(:airo, __MODULE__, [])

    %{
      enabled: Keyword.get(opts, :enabled, true),
      interval_ms: Keyword.get(opts, :interval_ms, 30_000),
      probe_timeout_ms: Keyword.get(opts, :probe_timeout_ms, 5_000)
    }
  end
end
