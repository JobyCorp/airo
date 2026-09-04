defmodule Airo.Agents do
  @moduledoc """
  Registered host-side control agents (Model 2). An agent is a per-host control
  plane that *manages* serving providers (slots) — it is **not** itself a provider.

  `register/2` is the registration entry point (driven by the agent's channel
  connect): it upserts the Agent by `host_id` and upserts each advertised slot as
  a **managed Provider** — `agent_id` set, `base_url` = the engine's real static
  endpoint, wire protocol `:openai`. Serving then goes straight to that
  `base_url`; lifecycle (load/unload/swap) goes to the agent's `control_url`.
  """
  require Logger

  import Ecto.Query, only: [from: 2]

  alias Airo.{Config, Repo}
  alias Airo.Config.{Agent, LaunchProfile}

  # A managed slot speaks plain OpenAI (llama-server/vLLM are compatible). The
  # fact that it's agent-managed is carried by `Provider.agent_id`, orthogonally.
  @managed_adapter :openai

  @doc "All agents, managed providers preloaded."
  def list_agents, do: Config.list_agents() |> Repo.preload(:providers)

  @doc "One agent with its managed providers."
  def get_agent(id), do: Config.get_agent!(id) |> Repo.preload(:providers)

  @doc """
  Register or refresh an agent and its serving slots from a channel payload:

      %{
        "agent" => %{"control_url" => "...", "version" => "...", "gpu" => %{...}},
        "slots" => [%{"port" => 8081, "base_url" => "http://host:8081/v1"}, ...]
      }

  Upserts the Agent (by `host_id`) and each slot as a managed Provider. Returns
  `{:ok, %{agent: agent, providers: [...], changes: [...]}}` — providers that
  upserted cleanly, and `{field, from, to}` for each identity field (`version`,
  `control_url`) this register changed, so the caller can record the transition.
  """
  def register(host_id, payload) when is_binary(host_id) and is_map(payload) do
    previous = Config.get_agent_by_host_id(host_id)

    with {:ok, agent} <- Config.upsert_agent(host_id, agent_attrs(payload)) do
      providers =
        payload
        |> Map.get("slots", [])
        |> Enum.map(&upsert_slot(agent, &1))
        |> Enum.flat_map(fn
          {:ok, provider} ->
            [provider]

          {:error, changeset} ->
            Logger.warning("agent #{host_id}: slot upsert failed: #{inspect(changeset.errors)}")
            []
        end)

      {:ok, %{agent: agent, providers: providers, changes: changes(previous, agent)}}
    end
  end

  # Identity fields whose change is a lifecycle event (S25). A heartbeat that
  # re-registers the same identity changes nothing and is not an event.
  @identity_fields [:version, :control_url]

  # Register is also the heartbeat, so the caller needs to know whether this one
  # carried a *different* identity than the row held. A first registration has
  # nothing to compare against — the `connected` event already covers it.
  defp changes(nil, _agent), do: []

  defp changes(%Agent{} = previous, %Agent{} = agent) do
    for field <- @identity_fields,
        from = Map.fetch!(previous, field),
        to = Map.fetch!(agent, field),
        from != to and not is_nil(to),
        do: {field, from, to}
  end

  defp agent_attrs(payload) do
    info = Map.get(payload, "agent", %{})

    # nil fields are dropped so a sparse re-register preserves prior values.
    %{
      control_url: info["control_url"],
      version: info["version"],
      gpu: info["gpu"],
      last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "Saved launch profile for a model id (the map the agent's `/load` takes), or nil."
  def launch_profile(model_name) when is_binary(model_name) do
    case Repo.get_by(LaunchProfile, model_name: model_name) do
      %LaunchProfile{profile: profile} -> profile
      nil -> nil
    end
  end

  @doc "Saved launch profiles for a set of model ids: `%{model_name => profile}`."
  def launch_profiles(model_names) when is_list(model_names) do
    from(lp in LaunchProfile, where: lp.model_name in ^model_names)
    |> Repo.all()
    |> Map.new(&{&1.model_name, &1.profile})
  end

  @doc """
  Save (upsert) the launch profile for a model id. The UI calls this on every
  load, so the last launch recipe is what the next load of the model starts from.
  """
  def save_launch_profile(model_name, profile) when is_binary(model_name) and is_map(profile) do
    %LaunchProfile{}
    |> LaunchProfile.changeset(%{model_name: model_name, profile: profile})
    |> Repo.insert(
      on_conflict: {:replace, [:profile, :updated_at]},
      conflict_target: :model_name
    )
  end

  @doc """
  Record the profile a slot is **actually running** as the model's launch recipe.

  The config modal is not the only way a model comes up: a hand-POSTed `/load`
  (`airo_agent`'s `deploy/payloads/*.json`), an agent-side restore after a
  restart, or any load Airo didn't initiate leaves no recipe behind. The next
  load out of the UI then starts from a guess — a modest context, single node,
  no image or engine env — which for a hand-tuned launch is silently wrong.
  Recording what the agent reports closes that: whoever launched it, the recipe
  that worked is the one on file.

  The agent sends the *effective* profile (its own defaults already resolved),
  so what lands here round-trips back through `/load` verbatim.

  Idempotent by value — the profile rides every heartbeat register, and a
  re-write per beat per slot would be pure churn.
  """
  def record_live_profile(model_name, profile) when is_binary(model_name) and is_map(profile) do
    cond do
      model_name == "" or profile == %{} ->
        :ok

      launch_profile(model_name) == profile ->
        :ok

      true ->
        case save_launch_profile(model_name, profile) do
          {:ok, _} ->
            Logger.info("recorded live launch profile for #{model_name}")
            :ok

          {:error, changeset} ->
            Logger.warning(
              "could not record live launch profile for #{model_name}: #{inspect(changeset.errors)}"
            )

            :ok
        end
    end
  end

  def record_live_profile(_model_name, _profile), do: :ok

  defp upsert_slot(%Agent{} = agent, slot) do
    name = "#{agent.host_id}:#{slot["port"]}"

    attrs = %{
      name: name,
      adapter_type: @managed_adapter,
      base_url: slot["base_url"],
      auth_kind: :none,
      agent_id: agent.id,
      enabled: true
    }

    case Config.get_provider_by_name(name) do
      nil -> Config.create_provider(attrs)
      provider -> Config.update_provider(provider, attrs)
    end
  end
end
