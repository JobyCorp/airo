defmodule AiroWeb.Admin.AgentLive do
  @moduledoc """
  Operator control plane for host-side agents (Model 2 — see `airo_agent/DESIGN.md`
  and `DESIGN-agent-management.md`). One agent per serving host: it manages the
  engine slots (Providers), pushes GPU telemetry + resident-slot state over its
  channel, and exposes a control API at `control_url`.

  State flows by push (no polling): online/offline via `Presence`, resident model
  per slot via `Airo.Agents.SlotState` — both delivered as subscriptions on the
  `agent:<host_id>` topic. Control flows by request: load / unload / swap and
  inventory browse go to the agent's `control_url` via `Airo.Agents.Control`, and
  only confirm acceptance — the slot transition arrives back as a push.
  """
  use AiroWeb, :live_view

  require Logger

  alias Airo.Agents
  alias Airo.Agents.{Capacity, Control, Ingest, SlotState}
  alias Airo.Config
  alias Airo.Repo
  alias AiroWeb.CompositeComponents
  alias AiroWeb.Presence

  # GPU telemetry and slot health are DB state written by the agent's channel
  # pushes (`Agents.Ingest`); a light timer re-reads them without a manual reload.
  # Online/offline is NOT on this timer — it's a Presence subscription (below).
  @refresh_ms 10_000

  # Launch-profile keys the config modal owns as first-class fields; everything
  # else a profile carries rides in the advanced-JSON editor verbatim.
  @form_profile_keys ~w(ctx disable_thinking repeat_penalty presence_penalty frequency_penalty nnodes tensor_parallel_size)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(page_title: "Agents", detail: nil, subscribed: MapSet.new())
     |> assign(config: nil, inventory: [], inventory_error: nil)
     |> assign_agents()
     |> subscribe_presence()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    # A periodic fallback that also picks up newly-registered agents (and
    # subscribes to them). Slot/presence changes are push-driven; this is belt
    # and suspenders for GPU telemetry and roster drift.
    {:noreply, socket |> refresh() |> subscribe_presence()}
  end

  # A host's Presence changed (connect/disconnect) — react immediately rather
  # than waiting for the next tick. Presence is a subscription, not a poll.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "agent:" <> host_id},
        socket
      ) do
    online = online?(host_id)

    socket =
      socket
      |> update(:online, &Map.put(&1, host_id, online))
      |> update_detail_online(host_id, online)

    {:noreply, socket}
  end

  # A slot's resident state changed (load/unload/swap reported by the agent, or a
  # host disconnect). Re-read from SlotState — push-driven, no poll.
  @impl true
  def handle_info({:agent_slots, _host_id}, socket), do: {:noreply, refresh(socket)}

  # The agent topic also carries channel control messages (e.g. our own "resync"
  # fanned out to the agent). We only act on presence diffs; ignore the rest.
  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  # Open the config modal for a model — Configure if it's resident in a slot,
  # otherwise Load into a target slot. Prefills the context window.
  @impl true
  def handle_event("open_config", %{"model" => id}, socket) do
    {:noreply, assign(socket, config: build_config(socket.assigns, id))}
  end

  def handle_event("cancel_config", _params, socket), do: {:noreply, assign(socket, config: nil)}

  def handle_event("config_change", %{"config" => params}, %{assigns: %{config: config}} = socket)
      when is_map(config) do
    config = %{
      config
      | ctx: params["ctx"],
        port: parse_int(params["port"], config.port),
        disable_thinking: params["disable_thinking"] == "true",
        repeat_penalty: params["repeat_penalty"] || config.repeat_penalty,
        presence_penalty: params["presence_penalty"] || config.presence_penalty,
        frequency_penalty: params["frequency_penalty"] || config.frequency_penalty,
        nnodes: parse_int(params["nnodes"], config.nnodes),
        tensor_parallel_size: params["tensor_parallel_size"] || config.tensor_parallel_size,
        launch_json: params["launch_json"] || config.launch_json
    }

    config = %{config | launch_error: launch_json_error(config.launch_json)}

    {:noreply, assign(socket, config: %{config | validation: validate_config(config)})}
  end

  def handle_event(
        "submit_config",
        %{"config" => params},
        %{assigns: %{detail: %{agent: agent}, config: config}} = socket
      )
      when is_map(config) do
    port = parse_int(params["port"], config.port)
    ctx = parse_int(params["ctx"], nil)
    nnodes = parse_int(params["nnodes"], 1)
    launch_json = params["launch_json"] || ""

    # The form owns its first-class fields; the advanced JSON carries the rest of
    # the launch recipe verbatim. String keys throughout — the merged map is the
    # exact profile POSTed to the agent and persisted for the next load.
    overrides =
      %{
        "ctx" => ctx,
        "disable_thinking" => if(params["disable_thinking"] == "true", do: true),
        "repeat_penalty" => parse_float(params["repeat_penalty"]),
        "presence_penalty" => parse_float(params["presence_penalty"]),
        "frequency_penalty" => parse_float(params["frequency_penalty"]),
        "nnodes" => if(nnodes > 1, do: nnodes),
        "tensor_parallel_size" => parse_int(params["tensor_parallel_size"], nil)
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    profile =
      launch_json
      |> parse_launch_json()
      |> Map.drop(@form_profile_keys)
      |> Map.merge(overrides)

    model_id = config.model["id"]
    verb = if config.mode == :configure, do: "Restarting", else: "Loading"
    validation = validate_config(%{config | ctx: params["ctx"], port: port, nnodes: nnodes})

    cond do
      launch_json_error(launch_json) ->
        {:noreply,
         put_flash(socket, :error, "Launch profile JSON: #{launch_json_error(launch_json)}.")}

      # Hard limit (A4): over-commit segfaults the engine, so refuse server-side
      # too, not only via the disabled button.
      validation.fits? == false ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Won't fit VRAM: ~#{gb(validation.projected_mb)} GB projected exceeds the #{gb(validation.budget_mb)} GB budget. Reduce the context."
         )}

      true ->
        Agents.save_launch_profile(model_id, profile)
        run_load(agent, port, model_id, profile, nnodes)

        {:noreply,
         socket
         |> assign(config: nil)
         |> update(:inventory, &with_launch_profiles/1)
         |> put_flash(:info, "#{verb} #{model_id} on slot #{port}… watch the slot for status.")}
    end
  end

  def handle_event("refresh_inventory", _params, %{assigns: %{detail: %{agent: agent}}} = socket) do
    case Control.refresh_inventory(agent) do
      {:ok, models} ->
        {:noreply, assign(socket, inventory: with_launch_profiles(models), inventory_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, inventory: [], inventory_error: describe(reason))}
    end
  end

  def handle_event("unload", %{"port" => port}, %{assigns: %{detail: %{agent: agent}}} = socket) do
    port = String.to_integer(port)

    case Control.unload(agent, port) do
      :accepted ->
        {:noreply, put_flash(socket, :info, "Unloading slot #{port}…")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unload failed: #{describe(reason)}")}
    end
  end

  def handle_event("resync", _params, %{assigns: %{detail: %{agent: agent}}} = socket) do
    AiroWeb.Endpoint.broadcast("agent:#{agent.host_id}", "resync", %{})
    {:noreply, put_flash(socket, :info, "Asked #{agent.host_id} to re-report its slots.")}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(detail: nil, page_title: "Agents")
    |> assign_agents()
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    detail = detail(id)

    socket
    |> assign(detail: detail, config: nil, page_title: detail.agent.host_id)
    |> assign_inventory()
  end

  # Loadable models for the host, fetched when it's online. Always-visible (no
  # hidden picker); empty + read-only when offline/unreachable.
  defp assign_inventory(%{assigns: %{detail: %{online: true, agent: agent}}} = socket) do
    case Control.inventory(agent) do
      {:ok, models} ->
        assign(socket, inventory: with_launch_profiles(models), inventory_error: nil)

      {:error, reason} ->
        assign(socket, inventory: [], inventory_error: describe(reason))
    end
  end

  defp assign_inventory(socket), do: assign(socket, inventory: [], inventory_error: nil)

  # Pair each inventory model with its saved launch profile (`:launch_profile`),
  # so fit math and the config modal know e.g. that a model launches as a
  # two-node cluster load.
  defp with_launch_profiles(models) do
    profiles = Agents.launch_profiles(Enum.map(models, & &1["id"]))
    Enum.map(models, &Map.put(&1, :launch_profile, profiles[&1["id"]] || %{}))
  end

  # Build the config-modal state for a model: Configure (resident → its slot +
  # current ctx, calibrated against its live VRAM) or Load (a target slot, the
  # model's ctx_max as a starting point, cold weights-floor validation).
  defp build_config(%{inventory: inventory, detail: detail}, id) do
    model = Enum.find(inventory, &(&1["id"] == id)) || %{"id" => id}
    gpu = detail.agent.gpu
    weights_mb = mb(model["size_bytes"])
    total_mb = gpu_val(gpu, :vram_total_mb)
    used_mb = gpu_val(gpu, :vram_used_mb)
    saved = Agents.launch_profile(id) || %{}

    base =
      case Enum.find(detail.slots, &(&1.resident_model == id)) do
        %{port: port, ctx: ctx, parallel: parallel, ctx_total: ctx_total, profile: profile} ->
          # No saved recipe for a resident model (loaded out of band, e.g. a
          # hand-POSTed cluster launch)? Seed from the slot's reported profile,
          # so a Restart reproduces the running launch instead of dropping it
          # to a bare single-node load.
          seed = if saved == %{}, do: profile || %{}, else: saved

          %{
            mode: :configure,
            model: model,
            port: port,
            slots: [port],
            parallel: parallel || 1,
            ctx: to_string(ctx || model["ctx_max"]),
            disable_thinking: reasoning_off?(profile),
            repeat_penalty: penalty_prefill(profile, :repeat_penalty),
            presence_penalty: penalty_prefill(profile, :presence_penalty),
            frequency_penalty: penalty_prefill(profile, :frequency_penalty),
            calib: %{
              resident?: true,
              weights_mb: weights_mb,
              used_mb: used_mb,
              total_mb: total_mb,
              ctx_total_current: ctx_total
            }
          }
          |> Map.merge(launch_prefills(seed))

        nil ->
          %{
            mode: :load,
            model: model,
            port: load_target_slot(detail.slots),
            slots: Enum.map(detail.slots, & &1.port),
            parallel: 1,
            # Prefill a modest window, not the model's full ctx_max: a cold
            # (non-resident) load has no KV calibration, so validation can't
            # catch a 262k window OOMing a 16 GB card. Big ctx is a deliberate
            # slide up, not the default. A saved recipe's ctx wins — it's a
            # window that already worked.
            ctx: to_string(saved["ctx"] || default_ctx(model["ctx_max"])),
            disable_thinking: saved["disable_thinking"] == true,
            repeat_penalty: penalty_prefill(saved, :repeat_penalty),
            presence_penalty: penalty_prefill(saved, :presence_penalty),
            frequency_penalty: penalty_prefill(saved, :frequency_penalty),
            calib: %{
              resident?: false,
              weights_mb: weights_mb,
              used_mb: used_mb,
              total_mb: total_mb,
              ctx_total_current: nil
            }
          }
          |> Map.merge(launch_prefills(saved))
      end

    Map.put(base, :validation, validate_config(base))
  end

  defp launch_prefills(profile) do
    tp = profile["tensor_parallel_size"] || profile[:tensor_parallel_size]

    %{
      nnodes: profile["nnodes"] || profile[:nnodes] || 1,
      tensor_parallel_size: if(tp, do: to_string(tp), else: ""),
      launch_json: profile |> stringify_keys() |> Map.drop(@form_profile_keys) |> launch_json(),
      launch_error: nil
    }
  end

  # A slot-reported profile arrives string-keyed; one we saved is too. Belt and
  # suspenders for locally-built maps.
  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp launch_json(map) when map_size(map) == 0, do: ""
  defp launch_json(map), do: Jason.encode!(map, pretty: true)

  defp launch_json_error(""), do: nil

  defp launch_json_error(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> nil
      {:ok, _other} -> "must be a JSON object"
      {:error, _} -> "invalid JSON"
    end
  end

  defp parse_launch_json(""), do: %{}

  defp parse_launch_json(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  # Project the chosen context against VRAM (A4). ctx_total' = ctx × parallel.
  # A multi-node load shards the weights — each host holds 1/n — so fit is
  # judged against this host's share.
  defp validate_config(config) do
    ctx = parse_int(config.ctx, nil)
    ctx_total_new = ctx && ctx * (config.parallel || 1)
    nnodes = max(config.nnodes || 1, 1)

    config.calib
    |> Map.update!(:weights_mb, fn mb -> mb && mb / nnodes end)
    |> Map.put(:ctx_total_new, ctx_total_new)
    |> Capacity.validate()
  end

  defp mb(bytes) when is_integer(bytes), do: bytes / 1_048_576
  defp mb(_bytes), do: nil

  # Prefer a free slot; otherwise the first slot (Load becomes a swap).
  defp load_target_slot(slots) do
    slot = Enum.find(slots, &(&1.status in [:empty, :down])) || List.first(slots)
    slot && slot.port
  end

  defp parse_int(value, default) do
    case value |> to_string() |> Integer.parse() do
      {n, _} -> n
      :error -> default
    end
  end

  # Blank/garbage → nil, so `Control.put_profile/2` drops the key and the
  # engine keeps its own default (repeat 1.0, presence/frequency 0 — all off).
  defp parse_float(value) do
    case value |> to_string() |> Float.parse() do
      {f, _} -> f
      :error -> nil
    end
  end

  # A cluster load boots two ranks over the fabric (NCCL init, sharded weight
  # load, CUDA-graph capture) — minutes, not seconds. The push still drives the
  # UI either way; the timeout only bounds the background ack task.
  @load_timeout 90_000
  @cluster_load_timeout 1_800_000

  # Load/restart runs off the LiveView process: the agent's /load blocks until the
  # engine is ready (can take many seconds), and the slot transition (loading → up)
  # arrives by push regardless. So fire it with a generous timeout and let the push
  # drive the UI — the operator isn't blocked.
  defp run_load(agent, port, model_id, profile, nnodes) do
    timeout = if nnodes > 1, do: @cluster_load_timeout, else: @load_timeout

    Task.Supervisor.start_child(Airo.Usage.TaskSupervisor, fn ->
      case Control.load(agent, port, model_id,
             profile: profile,
             req_options: [receive_timeout: timeout]
           ) do
        :accepted ->
          :ok

        {:error, reason} ->
          Logger.warning("agent #{agent.host_id} slot #{port} load failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Cold-load ctx prefill: modest by default (see build_config); nil ctx_max
  # renders the free-form number input empty.
  @default_ctx_prefill 32_768
  defp default_ctx(ctx_max) when is_integer(ctx_max), do: min(ctx_max, @default_ctx_prefill)
  defp default_ctx(_), do: nil

  # Does a resident slot's reported profile have thinking disabled? Used to
  # prefill the toggle when reconfiguring. The engine-neutral knob is the
  # `disable_thinking` profile key (each agent adapter maps it to its engine's
  # flag); slots loaded before that knob existed carry the legacy raw argv pair
  # `--reasoning off` in extra_argv, so keep recognizing it.
  defp reasoning_off?(profile) when is_map(profile) do
    knob = profile["disable_thinking"] || profile[:disable_thinking]

    argv = (profile["extra_argv"] || profile[:extra_argv] || []) |> Enum.map(&to_string/1)

    legacy? =
      argv
      |> Enum.drop_while(&(&1 != "--reasoning"))
      |> case do
        ["--reasoning", "off" | _] -> true
        _ -> false
      end

    knob == true or legacy?
  end

  defp reasoning_off?(_profile), do: false

  # Node span of a slot's reported launch profile, or nil for single-host.
  defp profile_nnodes(profile) when is_map(profile) do
    case profile["nnodes"] || profile[:nnodes] do
      n when is_integer(n) and n > 1 -> n
      _ -> nil
    end
  end

  defp profile_nnodes(_profile), do: nil

  # A slot's reported profile arrives as JSON (string keys); a profile we just
  # built locally has atom keys. Read either.
  defp profile_penalty(profile, key) when is_map(profile),
    do: profile[Atom.to_string(key)] || profile[key]

  defp profile_penalty(_profile, _key), do: nil

  # Form value for the config modal: the slot's current setting, or blank
  # (= engine default) when the launch never set one.
  defp penalty_prefill(profile, key) do
    case profile_penalty(profile, key) do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp assign_agents(socket) do
    agents = list()
    assign(socket, agents: agents, online: online_map(agents))
  end

  # Subscribe to each agent we aren't already watching: its Presence topic
  # (`agent:<host_id>`, for connect/disconnect diffs) and its slot-state topic
  # (`Ingest.slots_topic/1`, for load/unload/swap). Idempotent — `subscribed`
  # tracks which hosts we hold, so re-listing never double-subscribes.
  defp subscribe_presence(%{assigns: %{agents: agents, subscribed: subscribed}} = socket) do
    if connected?(socket) do
      subscribed =
        Enum.reduce(agents, subscribed, fn agent, acc ->
          if MapSet.member?(acc, agent.host_id) do
            acc
          else
            Phoenix.PubSub.subscribe(Airo.PubSub, "agent:#{agent.host_id}")
            Phoenix.PubSub.subscribe(Airo.PubSub, Ingest.slots_topic(agent.host_id))
            MapSet.put(acc, agent.host_id)
          end
        end)

      assign(socket, subscribed: subscribed)
    else
      socket
    end
  end

  defp update_detail_online(
         %{assigns: %{detail: %{agent: %{host_id: host_id}} = detail}} = socket,
         host_id,
         online
       ),
       do: assign(socket, detail: %{detail | online: online})

  defp update_detail_online(socket, _host_id, _online), do: socket

  defp list do
    Config.list_agents() |> Repo.preload(providers: :deployments)
  end

  defp detail(id) do
    agent = Config.get_agent!(id) |> Repo.preload(providers: :deployments)

    %{
      agent: agent,
      online: online?(agent.host_id),
      slots: Enum.map(agent.providers, &slot_view/1)
    }
  end

  # A managed Provider is a slot. Its resident model + status are runtime state
  # the agent pushed (`SlotState`) — not inferred from deployments, since loading
  # a model writes no deployment row. No state yet ⇒ treat the slot as empty.
  defp slot_view(provider) do
    state = SlotState.get(provider.id) || %{}

    %{
      provider: provider,
      port: slot_port(provider),
      resident_model: state[:resident_model],
      revision: state[:revision],
      status: state[:status] || :empty,
      ctx: state[:ctx],
      parallel: state[:parallel],
      ctx_total: state[:ctx_total],
      engine_build: state[:engine_build],
      profile: state[:profile] || %{},
      deployment_count: length(provider.deployments)
    }
  end

  # The serving port is the slot's identity for control calls; it's the suffix of
  # the registered name "<host_id>:<port>".
  defp slot_port(%{name: name}) do
    case name |> to_string() |> String.split(":") |> List.last() |> Integer.parse() do
      {port, _} -> port
      :error -> nil
    end
  end

  defp refresh(socket) do
    socket =
      case socket.assigns.detail do
        %{agent: %{id: id}} -> assign(socket, detail: detail(id))
        _ -> socket
      end

    assign_agents(socket)
  end

  defp describe(:no_control_url), do: "no control URL configured for this agent"
  defp describe({:unknown_model, id}), do: "the host doesn't have #{id}"

  defp describe({:rejected, status, reason}),
    do: "agent rejected it (#{status}): #{inspect(reason)}"

  defp describe({:http_error, status, reason}), do: "HTTP #{status}: #{inspect(reason)}"
  defp describe({:transport_error, _reason}), do: "the host is unreachable"
  defp describe(other), do: inspect(other)

  defp online_map(agents), do: Map.new(agents, &{&1.host_id, online?(&1.host_id)})

  # Presence is the poll-free liveness signal: a connected agent tracks itself on
  # its own `agent:<host_id>` topic (see `AiroWeb.AgentChannel`). Reads local
  # Presence ETS for the current truth; the subscription delivers the changes.
  defp online?(host_id), do: Presence.list("agent:#{host_id}") != %{}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="agents">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle={agents_subtitle(@live_action, @detail)}>
          <:crumb navigate={~p"/admin/agents"}>Agents</:crumb>
          <:crumb :if={@live_action == :show}>{@detail.agent.host_id}</:crumb>
          <:actions :if={@live_action == :show}>
            <.button size="sm" phx-click="resync" disabled={!@detail.online}>Resync</.button>
            <.button size="sm" navigate={~p"/admin/agents"}>Back</.button>
          </:actions>
        </CompositeComponents.page_header>

        <%= if @detail do %>
          <.agent_detail
            detail={@detail}
            config={@config}
            inventory={@inventory}
            inventory_error={@inventory_error}
          />
        <% else %>
          <.agent_table agents={@agents} online={@online} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp agents_subtitle(:show, _detail), do: "Host control plane: GPU posture and managed slots."
  defp agents_subtitle(_index, _detail), do: "Host-side control agents managing serving slots."

  attr :agents, :list, required: true
  attr :online, :map, required: true

  defp agent_table(assigns) do
    ~H"""
    <CompositeComponents.empty_state
      :if={@agents == []}
      icon="hero-server-stack"
      title="No agents registered"
    >
      A host running <span class="font-mono">airo_agent</span>
      registers itself here when it connects. Set <span class="font-mono">AIRO_SOCKET_URL</span>
      on the host to point at this server's <span class="font-mono">/agent</span>
      socket.
    </CompositeComponents.empty_state>

    <.table
      :if={@agents != []}
      id="agents"
      rows={@agents}
      row_click={fn agent -> JS.navigate(~p"/admin/agents/#{agent.id}") end}
    >
      <:col :let={agent} label="Host">{agent.host_id}</:col>
      <:col :let={agent} label="Status">
        <.presence_tag online={@online[agent.host_id]} />
      </:col>
      <:col :let={agent} label="GPU / VRAM">{gpu_summary(agent.gpu)}</:col>
      <:col :let={agent} label="Util">{gpu_util(agent.gpu)}</:col>
      <:col :let={agent} label="Slots">{length(agent.providers)}</:col>
      <:col :let={agent} label="Version">{present(agent.version)}</:col>
      <:col :let={agent} label="Last seen">{format_at(agent.last_seen_at)}</:col>
      <:action :let={agent}>
        <.icon_button
          icon="hero-arrow-top-right-on-square"
          label={"Open #{agent.host_id}"}
          navigate={~p"/admin/agents/#{agent.id}"}
        />
      </:action>
    </.table>
    """
  end

  attr :detail, :map, required: true
  attr :config, :any, required: true
  attr :inventory, :list, required: true
  attr :inventory_error, :any, required: true

  defp agent_detail(assigns) do
    assigns =
      assigns
      |> assign(loaded: Enum.count(assigns.detail.slots, &(&1.status == :up)))
      |> assign(model_rows: model_rows(assigns))

    ~H"""
    <div class="space-y-6">
      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <CompositeComponents.stat_tile label="Status">
          <.presence_tag online={@detail.online} />
        </CompositeComponents.stat_tile>
        <CompositeComponents.stat_tile label="Slots">
          {length(@detail.slots)}
          <:sub :if={@detail.slots != []}>{@loaded} loaded</:sub>
        </CompositeComponents.stat_tile>
        <CompositeComponents.stat_tile label="Version">
          {present(@detail.agent.version)}
        </CompositeComponents.stat_tile>
        <CompositeComponents.stat_tile label="Last seen">
          <span class="text-base">{format_at(@detail.agent.last_seen_at)}</span>
        </CompositeComponents.stat_tile>
      </div>

      <.card variant="bordered">
        <:title>GPU posture</:title>
        <%= if gpu_available?(@detail.agent.gpu) do %>
          <div class="mt-2 space-y-5">
            <div>
              <CompositeComponents.meter
                label="VRAM"
                value={gpu_val(@detail.agent.gpu, :vram_used_mb)}
                max={gpu_val(@detail.agent.gpu, :vram_total_mb)}
                display={gpu_summary(@detail.agent.gpu)}
              />
              <p :if={free_gb(@detail.agent.gpu)} class="mt-1 text-right text-xs text-base-content/50">
                {free_gb(@detail.agent.gpu)} GB free
              </p>
            </div>
            <CompositeComponents.meter
              label="GPU utilization"
              value={gpu_val(@detail.agent.gpu, :util_pct)}
              max={100}
            />
            <CompositeComponents.meter
              label="Power draw"
              value={gpu_val(@detail.agent.gpu, :power_draw_w)}
              max={gpu_val(@detail.agent.gpu, :power_limit_w)}
              display={gpu_power(@detail.agent.gpu)}
            />
          </div>
        <% else %>
          <p class="mt-1 text-sm text-base-content/55">No GPU telemetry reported by this host.</p>
        <% end %>
      </.card>

      <.card variant="bordered">
        <:title>Managed slots</:title>
        <p :if={!@detail.online} class="-mt-1 mb-3 text-xs text-base-content/55">
          Controls are disabled while the host is offline.
        </p>
        <CompositeComponents.empty_state
          :if={@detail.slots == []}
          icon="hero-square-3-stack-3d"
          title="No slots yet"
        >
          This agent hasn't registered any serving slots. They appear once it
          advertises its engine ports to Airo.
        </CompositeComponents.empty_state>
        <.table :if={@detail.slots != []} id="agent-slots" rows={@detail.slots}>
          <:col :let={slot} label="Slot">{slot.provider.name}</:col>
          <:col :let={slot} label="Resident model">
            <span class={[is_nil(slot.resident_model) && "text-base-content/40"]}>
              {present(slot.resident_model)}
            </span>
            <div :if={slot.revision} class="font-mono text-xs text-base-content/50">
              {slot.revision}
            </div>
          </:col>
          <:col :let={slot} label="Context">
            <span :if={slot.ctx} class="font-mono text-xs tabular-nums">{context_line(slot)}</span>
            <span :if={is_nil(slot.ctx)} class="text-base-content/40">—</span>
          </:col>
          <:col :let={slot} label="Serving">
            <.profile_tags profile={slot.profile} />
          </:col>
          <:col :let={slot} label="Status">
            <.slot_status_tag status={slot.status} />
          </:col>
          <:action :let={slot}>
            <.button
              :if={slot.resident_model}
              size="sm"
              phx-click="open_config"
              phx-value-model={slot.resident_model}
              disabled={!@detail.online or slot.status == :loading}
            >
              Configure
            </.button>
            <.button
              :if={slot.resident_model}
              size="sm"
              variant="danger"
              phx-click="unload"
              phx-value-port={slot.port}
              disabled={!@detail.online}
              data-confirm={"Unload #{slot.resident_model} from #{slot.provider.name}? In-flight requests to it will be interrupted."}
            >
              Unload
            </.button>
            <.icon_button
              icon="hero-arrow-top-right-on-square"
              label={"Open #{slot.provider.name}"}
              navigate={~p"/admin/providers/#{slot.provider.id}"}
            />
          </:action>
        </.table>
      </.card>

      <.card variant="bordered">
        <:eyebrow>Models on this host</:eyebrow>
        <:title>Loadable models</:title>
        <:actions>
          <.button size="sm" phx-click="refresh_inventory" disabled={!@detail.online}>
            Refresh
          </.button>
        </:actions>
        <p :if={@inventory_error} class="text-sm text-error">
          Inventory unavailable: {@inventory_error}
        </p>
        <CompositeComponents.empty_state
          :if={@detail.online and is_nil(@inventory_error) and @inventory == []}
          icon="hero-archive-box"
          title="No local models"
        >
          This host reports no models in its inventory. Acquisition is out of band.
        </CompositeComponents.empty_state>
        <p :if={!@detail.online} class="text-sm text-base-content/55">
          Connect the host to list and load its models.
        </p>
        <p :if={@model_rows != []} class="mb-3 text-xs text-base-content/55">
          Footprints are estimates; a “won't fit” flag is advisory. Configuring the loaded
          model restarts it.
        </p>
        <.table :if={@model_rows != []} id="inventory" rows={@model_rows}>
          <:col :let={model} label="Model">
            <span class="font-mono text-sm">{model["id"]}</span>
            <CompositeComponents.tag :if={model.resident?} tone="success">
              resident
            </CompositeComponents.tag>
          </:col>
          <:col :let={model} label="Footprint">
            <span class="tabular-nums">{footprint_gb(model.fit.footprint_mb)}</span>
            <CompositeComponents.tag :if={launch_nnodes(model) > 1} tone="primary">
              {launch_nnodes(model)}-node
            </CompositeComponents.tag>
            <CompositeComponents.tag
              :if={not model.resident? and model.fit.fits? == false}
              tone="warning"
            >
              won't fit
            </CompositeComponents.tag>
          </:col>
          <:col :let={model} label="Context max">
            <span class="font-mono text-xs tabular-nums text-base-content/60">
              {present(model["ctx_max"])}
            </span>
          </:col>
          <:action :let={model}>
            <.button
              size="sm"
              variant={if model.resident?, do: "secondary", else: "primary"}
              phx-click="open_config"
              phx-value-model={model["id"]}
              disabled={!@detail.online}
            >
              {if model.resident?, do: "Configure", else: "Load"}
            </.button>
          </:action>
        </.table>
      </.card>

      <.config_modal :if={@config} config={@config} />

      <.card variant="bordered">
        <:title>Control plane</:title>
        <dl class="grid gap-4 text-sm sm:grid-cols-3">
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/45">Host id</dt>
            <dd class="mt-0.5 font-mono">{@detail.agent.host_id}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/45">Control URL</dt>
            <dd class="mt-0.5 font-mono">{@detail.agent.control_url}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/45">Enabled</dt>
            <dd class="mt-0.5">{@detail.agent.enabled}</dd>
          </div>
        </dl>
      </.card>
    </div>
    """
  end

  attr :online, :boolean, required: true

  defp presence_tag(%{online: true} = assigns),
    do: ~H|<CompositeComponents.tag tone="success">online</CompositeComponents.tag>|

  defp presence_tag(assigns),
    do: ~H|<CompositeComponents.tag tone="neutral">offline</CompositeComponents.tag>|

  attr :status, :atom, required: true

  defp slot_status_tag(assigns) do
    {tone, label} =
      case assigns.status do
        :up -> {"success", "up"}
        :loading -> {"warning", "loading"}
        :down -> {"error", "down"}
        _empty -> {"neutral", "empty"}
      end

    assigns = assign(assigns, tone: tone, label: label)

    ~H"""
    <CompositeComponents.tag tone={@tone}>{@label}</CompositeComponents.tag>
    """
  end

  attr :config, :map, required: true

  defp config_modal(assigns) do
    ctx_value = parse_int(assigns.config.ctx, nil)
    parallel = assigns.config.parallel || 1
    validation = assigns.config.validation

    assigns =
      assign(assigns,
        ctx_max: assigns.config.model["ctx_max"],
        ctx_value: ctx_value,
        parallel: parallel,
        ctx_total: ctx_value && ctx_value * parallel,
        validation: validation,
        blocked?: validation.fits? == false,
        configure?: assigns.config.mode == :configure
      )

    ~H"""
    <CompositeComponents.modal id="slot-config" show on_cancel="cancel_config">
      <:title>
        {if @configure?, do: "Configure", else: "Load"}
        <span class="font-mono text-base">{@config.model["id"]}</span>
      </:title>
      <.form
        for={%{}}
        as={:config}
        id="config-form"
        phx-change="config_change"
        phx-submit="submit_config"
        class="space-y-4"
      >
        <.input
          :if={not @configure? and length(@config.slots) > 1}
          type="select"
          name="config[port]"
          value={@config.port}
          options={@config.slots}
          label="Slot"
        />
        <p :if={@configure? or length(@config.slots) <= 1} class="text-xs text-base-content/55">
          Slot {@config.port}
        </p>

        <CompositeComponents.slider
          :if={@ctx_max}
          name="config[ctx]"
          value={@ctx_value || @ctx_max}
          min={ctx_min(@ctx_max)}
          max={@ctx_max}
          step={ctx_step(@ctx_max)}
          label="Context window"
          phx-debounce="100"
        >
          <:readout>{ctx_display(@ctx_value, @ctx_max)}</:readout>
        </CompositeComponents.slider>
        <.input
          :if={is_nil(@ctx_max)}
          type="number"
          name="config[ctx]"
          value={@config.ctx}
          label="Context window"
          min="1"
        />

        <p :if={@ctx_value} class="text-xs text-base-content/55">
          {@ctx_value} per request × {@parallel} = <span class="font-mono">{@ctx_total}</span>
          total KV
        </p>

        <div>
          <.input
            type="checkbox"
            name="config[disable_thinking]"
            value={@config.disable_thinking}
            label="Disable thinking"
          />
          <p class="-mt-1 text-xs text-base-content/55">
            Launches the engine with reasoning traces off (llama.cpp <span class="font-mono">--reasoning off</span>, vLLM <span class="font-mono">enable_thinking: false</span>). Takes effect on {if @configure?,
              do: "restart",
              else: "load"}.
          </p>
        </div>

        <div>
          <p class="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-base-content/55">
            Sampling penalties
          </p>
          <div class="mt-1.5 grid grid-cols-3 gap-3">
            <.input
              type="number"
              name="config[repeat_penalty]"
              value={@config.repeat_penalty}
              label="Repeat"
              placeholder="1.0"
              min="0"
              max="2"
              step="0.05"
            />
            <.input
              type="number"
              name="config[presence_penalty]"
              value={@config.presence_penalty}
              label="Presence"
              placeholder="0"
              min="-2"
              max="2"
              step="0.1"
            />
            <.input
              type="number"
              name="config[frequency_penalty]"
              value={@config.frequency_penalty}
              label="Frequency"
              placeholder="0"
              min="-2"
              max="2"
              step="0.1"
            />
          </div>
          <p class="-mt-1 text-xs text-base-content/55">
            Engine defaults baked into the launch; a request that sends its own sampler
            params still overrides. Blank keeps the penalty off. Example: Qwen recommends
            presence <span class="font-mono">1.5</span> on quantized builds.
          </p>
        </div>

        <div>
          <p class="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-base-content/55">
            Launch
          </p>
          <div class="mt-1.5 grid grid-cols-2 gap-3">
            <.input
              type="select"
              name="config[nnodes]"
              value={@config.nnodes}
              options={["1 — this host": 1, "2 — cluster (2 hosts)": 2]}
              label="Nodes"
            />
            <.input
              type="number"
              name="config[tensor_parallel_size]"
              value={@config.tensor_parallel_size}
              label="Tensor parallel"
              placeholder="1"
              min="1"
              step="1"
            />
          </div>
          <p :if={@config.nnodes > 1} class="-mt-1 mb-2 text-xs text-base-content/55">
            Spans this host and its cabled cluster worker (vLLM multi-node, one slot).
            The host needs its cluster fabric configured and the weights already synced
            to the worker at the same snapshot path — otherwise the agent rejects the
            load. VRAM below is projected per host (weights ÷ nodes).
          </p>
          <.input
            type="textarea"
            name="config[launch_json]"
            value={@config.launch_json}
            label="Advanced launch profile (JSON)"
            placeholder={~s({"image": "…", "container_env": {…}, "extra_argv": […]})}
            class="min-h-32 font-mono text-xs"
            phx-debounce="300"
          />
          <p :if={@config.launch_error} class="-mt-1 text-xs text-error">
            {@config.launch_error}
          </p>
          <p class="-mt-1 text-xs text-base-content/55">
            Extra profile keys passed to the agent verbatim — e.g. <span class="font-mono">image</span>, <span class="font-mono">container_env</span>, <span class="font-mono">gpu_memory_utilization</span>, <span class="font-mono">kv_cache_dtype</span>, <span class="font-mono">extra_argv</span>. Saved per model on {if @configure?,
              do: "restart",
              else: "load"}, so the next load starts
            from this recipe.
          </p>
        </div>

        <div :if={@validation.projected_mb}>
          <CompositeComponents.meter
            label="VRAM (projected)"
            value={@validation.projected_mb}
            max={@config.calib.total_mb}
            display={vram_display(@validation)}
          />
          <p :if={@blocked?} class="mt-1 text-xs text-error">
            Over budget — won't fit. Projected ~{gb(@validation.projected_mb)} GB exceeds the {gb(
              @validation.budget_mb
            )} GB safe budget. Reduce the context.
          </p>
          <p :if={@validation.fits? == :cold} class="mt-1 text-xs text-base-content/55">
            Cold model: weights fit, but the context's KV cost can't be validated until it's loaded.
          </p>
        </div>

        <p :if={@configure?} class="text-xs text-warning">
          Restarting interrupts in-flight requests on slot {@config.port}.
        </p>

        <div class="flex justify-end gap-2 pt-2">
          <.button type="button" phx-click="cancel_config">Cancel</.button>
          <.button variant="primary" disabled={@blocked? or @config.launch_error != nil}>
            {if @configure?, do: "Restart with changes", else: "Load model"}
          </.button>
        </div>
      </.form>
    </CompositeComponents.modal>
    """
  end

  defp vram_display(%{projected_mb: p, budget_mb: b}) when is_number(p) and is_number(b),
    do: "#{gb(p)} / #{gb(b)} GB"

  defp vram_display(%{projected_mb: p}), do: "#{gb(p)} GB"

  attr :profile, :map, default: %{}

  defp profile_tags(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1">
      <CompositeComponents.tag :if={profile_nnodes(@profile)} tone="primary">
        {profile_nnodes(@profile)}-node
      </CompositeComponents.tag>
      <CompositeComponents.tag :if={@profile["cache_type_k"]} tone="neutral">
        KV {@profile["cache_type_k"]}
      </CompositeComponents.tag>
      <CompositeComponents.tag :if={@profile["flash_attn"] == "on"} tone="neutral">
        flash-attn
      </CompositeComponents.tag>
      <CompositeComponents.tag :if={@profile["spec_type"] == "draft-mtp"} tone="primary">
        MTP
      </CompositeComponents.tag>
      <CompositeComponents.tag :if={reasoning_off?(@profile)} tone="neutral">
        no-think
      </CompositeComponents.tag>
      <CompositeComponents.tag :if={profile_penalty(@profile, :repeat_penalty)} tone="neutral">
        repeat {profile_penalty(@profile, :repeat_penalty)}
      </CompositeComponents.tag>
      <CompositeComponents.tag :if={profile_penalty(@profile, :presence_penalty)} tone="neutral">
        presence {profile_penalty(@profile, :presence_penalty)}
      </CompositeComponents.tag>
      <CompositeComponents.tag :if={profile_penalty(@profile, :frequency_penalty)} tone="neutral">
        freq {profile_penalty(@profile, :frequency_penalty)}
      </CompositeComponents.tag>
    </div>
    """
  end

  defp context_line(%{ctx: ctx, parallel: parallel, ctx_total: total}) when is_integer(ctx),
    do: "#{ctx} × #{parallel || 1} = #{total || ctx}"

  defp context_line(_slot), do: "—"

  defp ctx_display(nil, max), do: "— / #{max}"
  defp ctx_display(value, max), do: "#{value} / #{max}"

  # Context-window slider bounds. A 1024 floor/step keeps stops on the round
  # values context tends to use; clamp the floor under tiny ceilings.
  defp ctx_min(max) when is_integer(max), do: min(1024, max)
  defp ctx_min(_max), do: 0
  defp ctx_step(max) when is_integer(max) and max <= 1024, do: max
  defp ctx_step(_max), do: 1024

  # --- capacity / memory-fit (S18) ---

  # Enrich each inventory model with a fit assessment and whether it's resident.
  # Fit is computed against the default load target (a swap there reclaims the
  # outgoing model's footprint). Sorted resident-first, then fits-first.
  defp model_rows(%{inventory: inventory, detail: detail}) do
    gpu = detail.agent.gpu

    resident_ids =
      for s <- detail.slots, s.resident_model, into: MapSet.new(), do: s.resident_model

    reclaim = reclaim_bytes(detail.slots, load_target_slot(detail.slots), inventory)

    inventory
    |> Enum.map(fn model ->
      # A model whose saved recipe spans n nodes only puts 1/n of its weights on
      # this host — judge the fit against that share.
      share = Capacity.shard_bytes(model["size_bytes"], launch_nnodes(model))

      Map.merge(model, %{
        fit: Capacity.assess(share, gpu, reclaim_bytes: reclaim),
        resident?: MapSet.member?(resident_ids, model["id"])
      })
    end)
    |> Enum.sort_by(fn m -> {if(m.resident?, do: 0, else: 1), fit_rank(m.fit.fits?)} end)
  end

  # Node count from a model's saved launch recipe (see `with_launch_profiles/1`).
  defp launch_nnodes(%{launch_profile: %{"nnodes" => n}}) when is_integer(n) and n > 1, do: n
  defp launch_nnodes(_model), do: 1

  # Size of the model currently resident in the target slot (freed on a swap), or
  # nil — this host's share of it, for a cluster resident.
  defp reclaim_bytes(slots, port, inventory) do
    with %{resident_model: id} when is_binary(id) <- Enum.find(slots, &(&1.port == port)),
         %{"size_bytes" => size} = model <- Enum.find(inventory, &(&1["id"] == id)) do
      Capacity.shard_bytes(size, launch_nnodes(model))
    else
      _ -> nil
    end
  end

  defp fit_rank(true), do: 0
  defp fit_rank(:unknown), do: 1
  defp fit_rank(false), do: 2

  defp free_gb(gpu) do
    case Capacity.headroom(gpu) do
      %{free_mb: free} -> Float.round(free / 1024, 1)
      :unavailable -> nil
    end
  end

  defp footprint_gb(mb) when is_number(mb), do: "~#{Float.round(mb / 1024, 1)} GB"
  defp footprint_gb(_mb), do: "—"

  # --- GPU formatting (channel pushes a JSON map → string keys) ---

  defp gpu_available?(gpu), do: gpu_val(gpu, :available) == true

  defp gpu_summary(gpu) do
    used = gpu_val(gpu, :vram_used_mb)
    total = gpu_val(gpu, :vram_total_mb)

    cond do
      is_number(used) and is_number(total) -> "#{gb(used)} / #{gb(total)} GB"
      is_number(total) -> "#{gb(total)} GB"
      true -> "—"
    end
  end

  defp gpu_util(gpu) do
    case gpu_val(gpu, :util_pct) do
      pct when is_number(pct) -> "#{round(pct)}%"
      _ -> "—"
    end
  end

  defp gpu_power(gpu) do
    draw = gpu_val(gpu, :power_draw_w)
    limit = gpu_val(gpu, :power_limit_w)

    cond do
      is_number(draw) and is_number(limit) -> "#{round(draw)} / #{round(limit)} W"
      is_number(draw) -> "#{round(draw)} W"
      true -> "—"
    end
  end

  defp gpu_val(gpu, key) when is_map(gpu), do: Map.get(gpu, key) || Map.get(gpu, to_string(key))
  defp gpu_val(_gpu, _key), do: nil

  defp gb(mb) when is_number(mb), do: Float.round(mb / 1024, 1)

  defp present(value) when value in [nil, ""], do: "—"
  defp present(value), do: value

  defp format_at(nil), do: "—"
  defp format_at(%DateTime{} = at), do: Calendar.strftime(at, "%b %d  %H:%M:%S")
end
