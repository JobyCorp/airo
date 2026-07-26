defmodule AiroWeb.MetricsController do
  @moduledoc """
  Prometheus exposition of the serving topology: `GET /metrics`.

  Same data as `GET /v1/serving`, shaped for anything that isn't orchester —
  Prometheus, Grafana, Alertmanager. Scrape with the management client key as a
  bearer token (`authorization` in the scrape config).

  ## Reading these series

  `airo_slot_status` and `airo_deployment_health` use the enum idiom — one
  series per possible state, exactly one of which is `1`. Alert on
  `airo_deployment_health{status="down"} == 1`, not on the absence of a series.

  `airo_deployment_health_stale` is the one to watch alongside it: Airo decays a
  health snapshot to `unknown` after its staleness window, so a `stale` reading
  means "nothing is reporting on this deployment", which is a different failure
  from "this deployment answered and said no".

  **Counter caveat:** the `_total` counters are derived from `usage_records`,
  which `Airo.Usage.PruneWorker` trims on a retention window. A prune makes them
  decrease, which Prometheus reads as a counter reset — `rate()` over a prune
  boundary will overstate. Keep the retention window well beyond your alerting
  windows, or graph the gauges instead.
  """
  use AiroWeb, :controller

  alias Airo.Serving

  @content_type "text/plain; version=0.0.4; charset=utf-8"

  def index(conn, _params) do
    snapshot = Serving.snapshot()
    usage = Serving.usage_rollup(group_by: :deployment, limit: 5_000)

    body =
      [
        host_metrics(snapshot.hosts),
        slot_metrics(snapshot.hosts),
        deployment_metrics(snapshot),
        alias_metrics(snapshot.aliases),
        usage_metrics(usage.rows)
      ]
      |> IO.iodata_to_binary()

    # Set the header directly: `put_resp_content_type/2` would append a second
    # `charset=`, and the exposition format carries its own `version=` parameter.
    conn
    |> put_resp_header("content-type", @content_type)
    |> send_resp(200, body)
  end

  ## Hosts

  defp host_metrics(hosts) do
    [
      metric(
        "airo_host_enabled",
        :gauge,
        "Whether the host agent is enabled in Airo.",
        hosts,
        fn h ->
          {[host_id: h.host_id], bool(h.enabled)}
        end
      ),
      metric(
        "airo_host_last_seen_timestamp_seconds",
        :gauge,
        "Unix time of the host agent's last channel push.",
        Enum.filter(hosts, & &1.last_seen_at),
        fn h -> {[host_id: h.host_id], DateTime.to_unix(to_datetime(h.last_seen_at))} end
      ),
      vram(
        "airo_host_vram_total_mb",
        "Total GPU VRAM reported by the host.",
        hosts,
        :vram_total_mb
      ),
      vram("airo_host_vram_used_mb", "GPU VRAM in use on the host.", hosts, :vram_used_mb),
      vram("airo_host_vram_free_mb", "GPU VRAM free on the host.", hosts, :vram_free_mb)
    ]
  end

  # Hosts with telemetry disabled report no series at all rather than a zero — a
  # missing reading must not look like an empty GPU to a scheduler or an alert.
  defp vram(name, help, hosts, key) do
    metric(name, :gauge, help, Enum.filter(hosts, & &1.gpu.available), fn h ->
      {[host_id: h.host_id], Map.fetch!(h.gpu, key)}
    end)
  end

  ## Slots

  @slot_statuses [:empty, :loading, :up, :down]

  defp slot_metrics(hosts) do
    slots = for host <- hosts, slot <- host.slots, do: {host, slot}
    resident = for {host, slot} <- slots, slot.resident, do: {host, slot}

    [
      metric(
        "airo_slot_status",
        :gauge,
        "Slot resident-model state; one series per state, exactly one set to 1.",
        for({host, slot} <- slots, status <- @slot_statuses, do: {host, slot, status}),
        fn {host, slot, status} ->
          current = (slot.resident && slot.resident.status) || :empty

          {[
             host_id: host.host_id,
             slot: slot.provider,
             model: (slot.resident && slot.resident.model) || "",
             status: status
           ], bool(current == status)}
        end
      ),
      slot_gauge("airo_slot_ctx", "Context length the slot is serving.", resident, :ctx),
      slot_gauge(
        "airo_slot_ctx_total",
        "Total context across the slot's parallel sequences.",
        resident,
        :ctx_total
      ),
      slot_gauge(
        "airo_slot_parallel",
        "Concurrent sequences the slot's engine was launched with.",
        resident,
        :parallel
      ),
      metric(
        "airo_slot_resident_since_timestamp_seconds",
        :gauge,
        "Unix time the slot's current model became resident.",
        Enum.filter(resident, fn {_h, s} -> s.resident.resident_since end),
        fn {host, slot} ->
          {[host_id: host.host_id, slot: slot.provider, model: slot.resident.model],
           DateTime.to_unix(slot.resident.resident_since)}
        end
      )
    ]
  end

  defp slot_gauge(name, help, resident, key) do
    metric(name, :gauge, help, Enum.filter(resident, fn {_h, s} -> s.resident[key] end), fn
      {host, slot} ->
        {[host_id: host.host_id, slot: slot.provider, model: slot.resident.model],
         Map.fetch!(slot.resident, key)}
    end)
  end

  ## Deployments

  @health_statuses [:up, :down, :unknown]

  defp deployment_metrics(snapshot) do
    # Managed slots and external providers are the same thing to a monitor; the
    # host_id label is empty for an upstream Airo doesn't manage.
    managed =
      for host <- snapshot.hosts,
          slot <- host.slots,
          deployment <- slot.deployments,
          do: {host.host_id, slot.provider, deployment}

    external =
      for provider <- snapshot.external_providers,
          deployment <- provider.deployments,
          do: {"", provider.provider, deployment}

    all = managed ++ external

    [
      metric(
        "airo_deployment_health",
        :gauge,
        "Deployment health; one series per state, exactly one set to 1.",
        for({h, p, d} <- all, status <- @health_statuses, do: {h, p, d, status}),
        fn {host_id, provider, deployment, status} ->
          {labels(host_id, provider, deployment) ++ [status: status],
           bool(deployment.health.status == status)}
        end
      ),
      deployment_gauge(
        "airo_deployment_health_stale",
        "1 when the health snapshot is older than Airo's staleness window.",
        all,
        &bool(&1.health.stale)
      ),
      deployment_gauge(
        "airo_deployment_eligible",
        "1 when the deployment passes Airo's hard config gate (deployment and provider enabled).",
        all,
        &bool(&1.eligible)
      ),
      deployment_gauge(
        "airo_deployment_routable",
        "1 when the deployment is eligible and healthy, i.e. Airo would prefer it.",
        all,
        &bool(&1.routable)
      ),
      metric(
        "airo_deployment_probe_latency_ms",
        :gauge,
        "Latency of the most recent health probe.",
        Enum.filter(all, fn {_h, _p, d} -> d.health.latency_ms end),
        fn {host_id, provider, deployment} ->
          {labels(host_id, provider, deployment), deployment.health.latency_ms}
        end
      )
    ]
  end

  defp deployment_gauge(name, help, all, value_fun) do
    metric(name, :gauge, help, all, fn {host_id, provider, deployment} ->
      {labels(host_id, provider, deployment), value_fun.(deployment)}
    end)
  end

  defp labels(host_id, provider, deployment) do
    [
      host_id: host_id,
      provider: provider,
      model_name: deployment.model_name,
      deployment_id: deployment.id
    ]
  end

  ## Aliases

  defp alias_metrics(aliases) do
    [
      alias_gauge(
        "airo_alias_candidates",
        "Deployments bound to the alias.",
        aliases,
        & &1.candidate_count
      ),
      alias_gauge(
        "airo_alias_routable_candidates",
        "Alias candidates that are eligible and healthy.",
        aliases,
        & &1.routable_candidates
      ),
      alias_gauge(
        "airo_alias_servable",
        "1 when at least one candidate passes the hard config gate.",
        aliases,
        &bool(&1.servable)
      )
    ]
  end

  defp alias_gauge(name, help, aliases, value_fun) do
    metric(name, :gauge, help, aliases, fn a ->
      {[alias: a.name, capability: a.capability], value_fun.(a)}
    end)
  end

  ## Usage counters

  defp usage_metrics(rows) do
    [
      usage_counter(
        "airo_requests_total",
        "Gateway calls served by the deployment.",
        rows,
        & &1.requests
      ),
      usage_counter(
        "airo_request_errors_total",
        "Gateway calls that errored.",
        rows,
        & &1.errors
      ),
      usage_counter(
        "airo_request_timeouts_total",
        "Gateway calls that timed out.",
        rows,
        & &1.timeouts
      ),
      usage_counter(
        "airo_fallbacks_total",
        "Calls that fell back from another candidate.",
        rows,
        & &1.fallbacks
      ),
      metric(
        "airo_tokens_total",
        :counter,
        "Tokens attributed to the deployment.",
        for(row <- rows, direction <- [:in, :out], do: {row, direction}),
        fn {row, direction} ->
          value = if direction == :in, do: row.tokens_in, else: row.tokens_out
          {usage_labels(row) ++ [direction: direction], value}
        end
      ),
      usage_counter("airo_cost_total", "Cost attributed to the deployment.", rows, & &1.cost)
    ]
  end

  defp usage_counter(name, help, rows, value_fun) do
    metric(name, :counter, help, rows, fn row -> {usage_labels(row), value_fun.(row)} end)
  end

  defp usage_labels(row) do
    [
      host_id: row.host_id || "",
      provider: row.provider,
      model_name: row.model_name,
      deployment_id: row.deployment_id
    ]
  end

  ## Exposition

  # A metric family with no samples is omitted entirely — emitting a bare HELP/TYPE
  # header with no series is legal but noisy in every scrape.
  defp metric(_name, _type, _help, [], _sample_fun), do: []

  defp metric(name, type, help, items, sample_fun) do
    [
      "# HELP ",
      name,
      " ",
      help,
      "\n# TYPE ",
      name,
      " ",
      to_string(type),
      "\n",
      Enum.map(items, fn item ->
        {labels, value} = sample_fun.(item)
        [name, render_labels(labels), " ", render_value(value), "\n"]
      end),
      "\n"
    ]
  end

  defp render_labels([]), do: []

  defp render_labels(labels) do
    [
      "{",
      Enum.map_join(labels, ",", fn {k, v} -> [to_string(k), "=\"", escape(v), "\""] end),
      "}"
    ]
  end

  # Prometheus label values escape backslash, double quote and newline; anything
  # else is passed through as UTF-8.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp render_value(value) when is_integer(value), do: Integer.to_string(value)
  defp render_value(value) when is_float(value), do: Float.to_string(value)
  defp render_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp render_value(value), do: to_string(value)

  defp bool(true), do: 1
  defp bool(_false), do: 0

  defp to_datetime(%DateTime{} = datetime), do: datetime
  defp to_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
end
