defmodule Airo.Config do
  @moduledoc """
  The configuration plane (DESIGN §8): CRUD over Providers, Deployments,
  Aliases (+ candidates), Secrets, and ClientKeys. This is Airo's single source
  of truth — the schema both consumer apps converge onto.

  Routing and request handling read from here; the admin UI (S6) writes through
  here. Health and per-call usage are deliberately *not* in this context
  (runtime ETS and `Airo.Usage`, respectively).
  """
  import Ecto.Query, warn: false

  alias Airo.Repo

  alias Airo.Config.{
    Agent,
    Alias,
    AliasCandidate,
    ClientKey,
    Deployment,
    Model,
    Provider,
    RoutingSetting,
    Secret
  }

  ## Routing setting (system classifier — S16)

  @doc """
  The singleton system classifier setting. Returns the persisted row, or an
  unpersisted default struct when none exists (fresh DB / tests).
  """
  def get_routing_setting do
    Repo.one(from r in RoutingSetting, limit: 1) || %RoutingSetting{}
  end

  @doc "Update (or insert) the singleton."
  def update_routing_setting(attrs) do
    case Repo.one(from r in RoutingSetting, limit: 1) do
      nil -> %RoutingSetting{}
      setting -> setting
    end
    |> RoutingSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def change_routing_setting(%RoutingSetting{} = setting, attrs \\ %{}),
    do: RoutingSetting.changeset(setting, attrs)

  @doc """
  The parsed system classifier config that `Airo.Routing.Classifier` consumes —
  the same shape the per-alias `router_config` used to produce. Read straight
  from the singleton (one indexed query, trivial vs. the inference it precedes —
  no cache, so it respects the test sandbox and needs no invalidation).
  """
  def routing_config do
    routing_config_from(get_routing_setting())
  end

  @doc """
  The parsed config for a given (possibly unpersisted) setting — used by the
  `/admin/routing` prompt-tester to preview unsaved edits.
  """
  def routing_config_from(%RoutingSetting{} = s) do
    %{
      backend: s.backend,
      classifier: s.classifier,
      model: s.model,
      score: if(map_size(s.score) > 0, do: s.score, else: :overall),
      labels: normalize_routing_labels(s.labels),
      template: s.hypothesis_template,
      default_class: s.default_class,
      input: to_string(s.input),
      timeout_ms: s.timeout_ms
    }
  end

  defp normalize_routing_labels(labels) when is_list(labels) do
    for entry <- labels,
        is_map(entry),
        is_binary(entry["class"]),
        is_number(entry["min"]),
        do: %{label: entry["label"], class: entry["class"], min: entry["min"]}
  end

  defp normalize_routing_labels(_), do: []

  ## Secrets

  def list_secrets, do: Repo.all(Secret)
  def get_secret!(id), do: Repo.get!(Secret, id)
  def get_secret_by_name(name), do: Repo.get_by(Secret, name: name)

  def create_secret(attrs) do
    %Secret{} |> Secret.changeset(attrs) |> Repo.insert()
  end

  def update_secret(%Secret{} = secret, attrs) do
    secret |> Secret.changeset(attrs) |> Repo.update()
  end

  def delete_secret(%Secret{} = secret), do: Repo.delete(secret)
  def change_secret(%Secret{} = secret, attrs \\ %{}), do: Secret.changeset(secret, attrs)

  ## Models

  def list_models do
    Model
    |> order_by([m], asc: m.display_name)
    |> Repo.all()
  end

  def list_models_with_deployments do
    Model
    |> order_by([m], asc: m.display_name)
    |> preload(deployments: [:provider])
    |> Repo.all()
  end

  def get_model!(id), do: Repo.get!(Model, id)

  def get_model_with_deployments!(id) do
    Model
    |> Repo.get!(id)
    |> Repo.preload(deployments: [:provider])
  end

  def get_model_by_upstream_id(upstream_model_id) do
    Repo.get_by(Model, upstream_model_id: upstream_model_id)
  end

  def create_model(attrs) do
    %Model{} |> Model.changeset(attrs) |> Repo.insert()
  end

  def update_model(%Model{} = model, attrs) do
    model |> Model.changeset(attrs) |> Repo.update()
  end

  def delete_model(%Model{} = model), do: Repo.delete(model)
  def change_model(%Model{} = model, attrs \\ %{}), do: Model.changeset(model, attrs)

  ## Providers

  def list_providers, do: Repo.all(Provider)
  def get_provider!(id), do: Repo.get!(Provider, id)
  def get_provider(id), do: Repo.get(Provider, id)
  def get_provider_by_name(name), do: Repo.get_by(Provider, name: name)

  ## Agents (Model 2 — host-side control planes that manage providers)

  def list_agents, do: Repo.all(from a in Agent, order_by: a.host_id)
  def get_agent!(id), do: Repo.get!(Agent, id)
  def get_agent_by_host_id(host_id), do: Repo.get_by(Agent, host_id: host_id)

  def create_agent(attrs), do: %Agent{} |> Agent.changeset(attrs) |> Repo.insert()

  def update_agent(%Agent{} = agent, attrs), do: agent |> Agent.changeset(attrs) |> Repo.update()

  @doc "Insert or update an agent by its durable `host_id`."
  def upsert_agent(host_id, attrs) when is_binary(host_id) do
    case get_agent_by_host_id(host_id) do
      nil -> create_agent(Map.put(attrs, :host_id, host_id))
      %Agent{} = agent -> update_agent(agent, attrs)
    end
  end

  @doc """
  Delete an agent whose host is gone — a renamed or retired box that will never
  register again and would otherwise sit in the roster as permanently offline.

  **Refuses while it still manages slots.** `providers.agent_id` is
  `on_delete: :nilify_all`, so deleting an agent that owns providers doesn't
  remove them — it strips their `agent_id` and leaves them behind looking like
  *external* providers. They'd start being probed (the prober skips
  agent-managed ones) and stay routable, under a `host:port` name nothing
  manages any more. That is a silent, hard-to-spot mess, so the slots have to be
  removed or reassigned first.

  Returns `{:error, {:has_providers, count}}` rather than doing it anyway.

  ## Cascading the empty slots

  That refusal is about *orphans*, and an empty slot can't become one: with no
  deployments pointing at it, nothing routes to it and removing it strands
  nothing. Requiring the operator to go delete it by hand on `/admin/providers`
  first is ceremony, so `cascade_empty_slots: true` takes those slots out with
  the agent, in one transaction. Slots that *do* carry deployments still block —
  and the reported count is then how many of those are in the way, not the total.
  """
  @spec delete_agent(Agent.t(), keyword()) ::
          {:ok, Agent.t()} | {:error, {:has_providers, pos_integer()} | Ecto.Changeset.t()}
  def delete_agent(%Agent{} = agent, opts \\ []) do
    %Agent{providers: providers} = agent = Repo.preload(agent, providers: :deployments)
    {empty, bound} = Enum.split_with(providers, &(&1.deployments == []))
    cascade? = Keyword.get(opts, :cascade_empty_slots, false)

    cond do
      providers == [] -> Repo.delete(agent)
      not cascade? -> {:error, {:has_providers, length(providers)}}
      bound != [] -> {:error, {:has_providers, length(bound)}}
      true -> delete_with_slots(agent, empty)
    end
  end

  defp delete_with_slots(agent, slots) do
    Repo.transaction(fn ->
      Enum.each(slots, &Repo.delete!/1)
      Repo.delete!(agent)
    end)
  end

  def create_provider(attrs) do
    %Provider{} |> Provider.changeset(attrs) |> Repo.insert()
  end

  def update_provider(%Provider{} = provider, attrs) do
    provider |> Provider.changeset(attrs) |> Repo.update()
  end

  def delete_provider(%Provider{} = provider), do: Repo.delete(provider)

  def change_provider(%Provider{} = provider, attrs \\ %{}),
    do: Provider.changeset(provider, attrs)

  ## Deployments

  def list_deployments, do: Repo.all(Deployment)
  def get_deployment!(id), do: Repo.get!(Deployment, id)

  @doc "The deployment for `model_name` under `provider_id` (unique), or nil."
  def get_deployment_by(provider_id, model_name),
    do: Repo.get_by(Deployment, provider_id: provider_id, model_name: model_name)

  @doc """
  Enabled deployments (with enabled providers) whose `model_name` matches and
  whose `capabilities` include `capability` — for resolving a concrete model id
  directly. Provider + credential preloaded.
  """
  def list_deployments_by_model(model_name, capability) do
    cap = to_string(capability)

    Deployment
    |> where(
      [d],
      d.model_name == ^model_name and fragment("? = ANY(?)", ^cap, d.capabilities) and
        d.enabled == true
    )
    |> preload(provider: :credential)
    |> Repo.all()
    |> Enum.filter(& &1.provider.enabled)
  end

  @doc """
  Enabled deployments (with enabled providers) whose `capabilities` include
  `capability`, regardless of model — for discovery that spans every deployment
  of a kind (e.g. listing TTS voices across all speech providers). Provider +
  credential preloaded.
  """
  def list_deployments_by_capability(capability) do
    cap = to_string(capability)

    Deployment
    |> where([d], fragment("? = ANY(?)", ^cap, d.capabilities) and d.enabled == true)
    |> preload(provider: :credential)
    |> Repo.all()
    |> Enum.filter(& &1.provider.enabled)
  end

  def create_deployment(attrs) do
    with {:ok, attrs} <- ensure_model_id(attrs) do
      %Deployment{} |> Deployment.changeset(attrs) |> Repo.insert()
    end
  end

  def update_deployment(%Deployment{} = deployment, attrs) do
    with {:ok, attrs} <- ensure_model_id(attrs) do
      deployment |> Deployment.changeset(attrs) |> Repo.update()
    end
  end

  def delete_deployment(%Deployment{} = deployment), do: Repo.delete(deployment)

  def change_deployment(%Deployment{} = deployment, attrs \\ %{}),
    do: Deployment.changeset(deployment, attrs)

  defp ensure_model_id(attrs) do
    attrs = stringify_keys(attrs)

    cond do
      present?(attrs["model_id"]) ->
        {:ok, attrs}

      present?(attrs["model_name"]) ->
        case get_or_create_model_for_deployment(attrs["model_name"]) do
          {:ok, model} -> {:ok, Map.put(attrs, "model_id", model.id)}
          {:error, _changeset} = error -> error
        end

      true ->
        {:ok, attrs}
    end
  end

  defp get_or_create_model_for_deployment(model_name) do
    case get_model_by_upstream_id(model_name) do
      nil ->
        create_model(%{
          display_name: model_name,
          upstream_model_id: model_name,
          status: :evaluating
        })

      model ->
        {:ok, model}
    end
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      entry -> entry
    end)
  end

  defp present?(value), do: value not in [nil, ""]

  ## Aliases

  def list_aliases, do: Repo.all(Alias)
  def get_alias!(id), do: Repo.get!(Alias, id)

  @doc "Fetch an alias by its logical name, preloading routing candidates."
  def get_alias_by_name(name) do
    Alias |> Repo.get_by(name: name) |> Repo.preload(:candidates)
  end

  def create_alias(attrs) do
    %Alias{} |> Alias.changeset(attrs) |> Repo.insert()
  end

  def update_alias(%Alias{} = alias_, attrs) do
    alias_ |> Repo.preload(:candidates) |> Alias.changeset(attrs) |> Repo.update()
  end

  def delete_alias(%Alias{} = alias_), do: Repo.delete(alias_)
  def change_alias(%Alias{} = alias_, attrs \\ %{}), do: Alias.changeset(alias_, attrs)

  @doc "An alias with its routing candidates (and their deployments) preloaded."
  def get_alias_with_candidates!(id) do
    Alias |> Repo.get!(id) |> Repo.preload(candidates: :deployment)
  end

  def add_alias_candidate(alias_id, attrs) do
    %AliasCandidate{}
    |> AliasCandidate.changeset(attrs |> stringify_keys() |> Map.put("alias_id", alias_id))
    |> Repo.insert()
  end

  def delete_alias_candidate(id) do
    AliasCandidate |> Repo.get!(id) |> Repo.delete()
  end

  ## Client keys

  def list_client_keys, do: Repo.all(ClientKey)
  def get_client_key!(id), do: Repo.get!(ClientKey, id)

  @doc "Look up a client key by the SHA-256 hash of a presented raw key."
  def get_client_key_by_hash(hashed_key) do
    Repo.get_by(ClientKey, hashed_key: hashed_key)
  end

  @doc """
  Mint a new client key. Returns `{:ok, client_key}` where the struct's virtual
  `:key` holds the raw key — surface it to the operator once; it is never stored.
  """
  def mint_client_key(attrs) do
    %ClientKey{} |> ClientKey.mint_changeset(attrs) |> Repo.insert()
  end

  def update_client_key(%ClientKey{} = client_key, attrs) do
    client_key |> ClientKey.changeset(attrs) |> Repo.update()
  end

  def delete_client_key(%ClientKey{} = client_key), do: Repo.delete(client_key)

  def change_client_key(%ClientKey{} = client_key, attrs \\ %{}),
    do: ClientKey.changeset(client_key, attrs)
end
