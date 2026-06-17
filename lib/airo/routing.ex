defmodule Airo.Routing do
  @moduledoc """
  Turns an alias (plus the request's optional `route` object) into an **ordered
  list of candidate deployments to try** (DESIGN §9). The order is the failover
  order: the gateway dispatches the head, advancing on retryable failures.

  Ordering rules, in effect:

    - **Enabled only** — disabled deployments/providers are dropped.
    - **Capability** — only deployments whose `capabilities` include the requested
      resource survive (skipped when no capability is passed).
    - **Route filters** — `route.class` and `route.tools` narrow the candidates.
    - **Strategy** — `:priority` (lowest first), `:weighted` (Efraimidis–Spirakis
      weighted shuffle), or `:round_robin` (rotated each call via an ETS counter).
    - **Health preference** — `:up` before `:unknown` before `:down`, applied as
      a *stable* re-sort so it never overrides strategy within a tier. Health is
      a preference, not a gate: a `:down` candidate is still tried last.
    - **Fallback chain** — after this alias's candidates, the candidates of each
      fallback alias (`route.fallback` overrides the alias's own `fallback`), one
      level deep, de-duplicated by deployment.

  **Strict pin:** when `route.binding` is set, exactly the matching deployment is
  returned (no strategy, no fallback, no substitution); if it isn't an enabled
  candidate of the alias, `{:error, :selected_binding_unavailable}` (ORC-073).
  """

  alias Airo.{Config, Health, Repo}
  alias Airo.Runtime.Store

  @type candidate :: %{deployment: Airo.Config.Deployment.t(), provider: Airo.Config.Provider.t()}

  @doc """
  Ordered candidates for an alias under `route` (a string-keyed map; `%{}` for
  none), filtered to deployments whose `capabilities` include `capability` (the
  resource being requested; pass `nil` to skip the capability filter). See the
  moduledoc for the ordering and the strict-pin behavior.
  """
  @spec candidates(Airo.Config.Alias.t(), map(), atom() | nil) ::
          {:ok, [candidate()]} | {:error, :no_deployment | :selected_binding_unavailable}
  def candidates(alias_, route, capability \\ nil) when is_map(route) do
    case route["binding"] do
      nil -> chained_candidates(alias_, route, capability)
      binding -> pinned_candidate(alias_, binding)
    end
  end

  @doc """
  Candidates for a set of deployments resolved by concrete model id (no alias).
  Health-ordered (`:up` first) so multiple deployments of the same model fail
  over like alias candidates, but with no weight/priority strategy.
  """
  @spec deployment_candidates([Airo.Config.Deployment.t()]) :: [candidate()]
  def deployment_candidates(deployments) do
    deployments
    |> Enum.sort_by(&health_rank(&1.id))
    |> Enum.map(&%{deployment: &1, provider: &1.provider})
  end

  ## Strict pin

  defp pinned_candidate(alias_, binding) do
    case Enum.find(enabled_candidates(alias_), &binding_matches?(&1, binding)) do
      nil -> {:error, :selected_binding_unavailable}
      candidate -> {:ok, [to_candidate(candidate)]}
    end
  end

  defp binding_matches?(%{deployment: deployment}, binding) do
    provider = deployment.provider

    binding == "#{provider.adapter_type}:#{deployment.model_name}" or
      binding == "#{provider.name}:#{deployment.model_name}"
  end

  ## Strategy + fallback chain

  defp chained_candidates(alias_, route, capability) do
    fallback_names = route["fallback"] || alias_.fallback

    ordered =
      [alias_ | fallback_aliases(fallback_names)]
      |> Enum.flat_map(&ordered_alias_candidates(&1, route, capability))
      |> Enum.uniq_by(& &1.deployment.id)

    case ordered do
      [] -> {:error, :no_deployment}
      list -> {:ok, Enum.map(list, &to_candidate/1)}
    end
  end

  # Returns AliasCandidate structs (carrying weight/priority), filtered by
  # capability + route, ordered by strategy, then stably re-sorted by health.
  defp ordered_alias_candidates(alias_, route, capability) do
    alias_
    |> enabled_candidates()
    |> filter_capability(capability)
    |> filter_route(route)
    |> strategy_order(alias_)
    |> Enum.sort_by(&health_rank(&1.deployment.id))
  end

  defp fallback_aliases(names) when is_list(names) do
    names |> Enum.map(&Config.get_alias_by_name/1) |> Enum.reject(&is_nil/1)
  end

  defp fallback_aliases(_), do: []

  ## Filters

  # Capability is the resource the client requested; keep only deployments whose
  # capability set serves it. `nil` skips the filter (e.g. strict pins).
  defp filter_capability(candidates, nil), do: candidates

  defp filter_capability(candidates, capability),
    do: Enum.filter(candidates, &(capability in &1.deployment.capabilities))

  defp filter_route(candidates, route) do
    candidates
    |> filter_class(route["class"])
    |> filter_tools(route["tools"])
  end

  defp filter_class(candidates, class) when is_binary(class),
    do: Enum.filter(candidates, &(to_string(&1.deployment.class) == class))

  defp filter_class(candidates, _), do: candidates

  defp filter_tools(candidates, true), do: Enum.filter(candidates, & &1.deployment.tool_use)
  defp filter_tools(candidates, _), do: candidates

  ## Strategy ordering

  defp strategy_order(candidates, %{strategy: :priority}), do: priority_order(candidates)
  defp strategy_order(candidates, %{strategy: :weighted}), do: weighted_order(candidates)

  defp strategy_order(candidates, %{strategy: :round_robin} = alias_),
    do: round_robin_order(candidates, alias_.id)

  defp priority_order(candidates),
    do: Enum.sort_by(candidates, &{&1.priority, &1.deployment_id})

  # Efraimidis–Spirakis weighted ordering: key = u^(1/weight), highest first.
  defp weighted_order(candidates) do
    candidates
    |> Enum.map(&{:math.pow(:rand.uniform(), 1.0 / max(&1.weight, 1)), &1})
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.map(&elem(&1, 1))
  end

  defp round_robin_order(candidates, alias_id) do
    ordered = priority_order(candidates)
    n = length(ordered)
    if n <= 1, do: ordered, else: rotate(ordered, rr_index(alias_id, n))
  end

  # Cyclic 0..n-1 counter per alias via an atomic ETS update.
  defp rr_index(alias_id, n) do
    :ets.update_counter(
      Store.routing_table(),
      {:rr, alias_id},
      {2, 1, n - 1, 0},
      {{:rr, alias_id}, -1}
    )
  end

  defp rotate(list, 0), do: list

  defp rotate(list, i) do
    {head, tail} = Enum.split(list, i)
    tail ++ head
  end

  ## Helpers

  defp enabled_candidates(alias_) do
    alias_
    |> Repo.preload(candidates: [deployment: [provider: :credential]])
    |> Map.fetch!(:candidates)
    |> Enum.filter(fn candidate ->
      deployment = candidate.deployment
      deployment && deployment.enabled && deployment.provider && deployment.provider.enabled
    end)
  end

  defp health_rank(deployment_id) do
    case Health.status(deployment_id) do
      :up -> 0
      :unknown -> 1
      :down -> 2
    end
  end

  defp to_candidate(%{deployment: deployment}),
    do: %{deployment: deployment, provider: deployment.provider}
end
