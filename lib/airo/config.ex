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
  alias Airo.Config.{Alias, AliasCandidate, ClientKey, Deployment, Provider, Secret}

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

  ## Providers

  def list_providers, do: Repo.all(Provider)
  def get_provider!(id), do: Repo.get!(Provider, id)
  def get_provider_by_name(name), do: Repo.get_by(Provider, name: name)

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

  def create_deployment(attrs) do
    %Deployment{} |> Deployment.changeset(attrs) |> Repo.insert()
  end

  def update_deployment(%Deployment{} = deployment, attrs) do
    deployment |> Deployment.changeset(attrs) |> Repo.update()
  end

  def delete_deployment(%Deployment{} = deployment), do: Repo.delete(deployment)

  def change_deployment(%Deployment{} = deployment, attrs \\ %{}),
    do: Deployment.changeset(deployment, attrs)

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
    |> AliasCandidate.changeset(Map.put(attrs, "alias_id", alias_id))
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
