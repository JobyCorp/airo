defmodule Airo.Gateway.Params do
  @moduledoc """
  Param normalization v1 (DESIGN §7).

  The request is already canonical (OpenAI-shaped), so normalization is about
  *layering defaults* and *honoring escape hatches*, not translating vocabulary
  (per-adapter `translate_params` for non-OpenAI upstreams arrives with the
  Anthropic adapter in S5).

  Resolution, lowest to highest precedence:

      provider.default_params
        < deployment.default_params
        < alias.default_params
        < request body
        < request `provider_params`   (raw passthrough, bypasses any translation)

  Maps are deep-merged so nested option bags (e.g. `chat_template_kwargs`) layer
  field-by-field rather than wholesale-replacing.

  Gateway-only extension keys are stripped before dispatch: `route` (routing
  intent, consumed upstream of here), `provider_params` (folded in raw) and
  `reasoning_effort_levels` (the clamp below). Every other key — known or
  unknown — passes through untouched.

  ## The effort clamp

  Clients speak one graded vocabulary for `reasoning_effort`; each backend's
  chat template accepts its own subset and spelling, and vLLM 400s on a value
  it does not know (Qwen3.8's template takes only `low`, `medium`, `xhigh`
  and rejects `high` and `max`; GLM 5.3's takes `max`). airo owns the
  spelling, so a deployment (or provider, or alias — same layering) can
  declare what its template accepts in its request defaults:

      "reasoning_effort_levels": ["low", "medium", "xhigh"]

  A requested effort that is on the list passes through. One that is not is
  clamped to the highest listed level at or below it on the ladder
  `none < minimal < low < medium < high < xhigh < max`, else to the lowest
  listed level — never above what was asked. A spelling not on the ladder
  is left alone (the operator wrote it on purpose). The key itself never
  reaches the backend.
  """

  @gateway_only_keys ~w(route provider_params reasoning_effort_levels)
  @effort_ladder ~w(none minimal low medium high xhigh max)
  @effort_rank @effort_ladder |> Enum.with_index() |> Map.new()

  @doc """
  Build the upstream request body from the client `params` and the resolved
  config layers (`:provider`, `:deployment`, `:alias`, each a schema struct with
  a `default_params` map).
  """
  @spec normalize(map(), %{provider: map(), deployment: map(), alias: map() | nil}) :: map()
  def normalize(params, %{provider: provider, deployment: deployment} = layers)
      when is_map(params) do
    provider_params = Map.get(params, "provider_params", %{})
    request = Map.drop(params, @gateway_only_keys)

    %{}
    |> deep_merge(provider.default_params || %{})
    |> deep_merge(deployment.default_params || %{})
    |> deep_merge(alias_params(layers[:alias]))
    |> deep_merge(request)
    |> deep_merge(provider_params)
    |> clamp_effort()
  end

  @doc """
  The effort clamp on its own (see the moduledoc): `levels` is what the
  template accepts, `effort` what was asked. Returns the value to send.
  """
  @spec clamp(String.t(), [String.t()]) :: String.t()
  def clamp(effort, levels) when is_binary(effort) and is_list(levels) and levels != [] do
    cond do
      effort in levels ->
        effort

      not Map.has_key?(@effort_rank, effort) ->
        effort

      true ->
        ranked =
          levels
          |> Enum.filter(&Map.has_key?(@effort_rank, &1))
          |> Enum.sort_by(&@effort_rank[&1])

        at_or_below = Enum.filter(ranked, &(@effort_rank[&1] <= @effort_rank[effort]))
        List.last(at_or_below) || List.first(ranked) || effort
    end
  end

  def clamp(effort, _levels), do: effort

  defp clamp_effort(%{"reasoning_effort_levels" => levels} = params) do
    params = Map.delete(params, "reasoning_effort_levels")

    case params do
      %{"reasoning_effort" => effort}
      when is_binary(effort) and is_list(levels) and levels != [] ->
        Map.put(params, "reasoning_effort", clamp(effort, levels))

      _ ->
        params
    end
  end

  defp clamp_effort(params), do: params

  # The alias param-layer is absent when resolving a concrete deployment model.
  defp alias_params(nil), do: %{}
  defp alias_params(alias_), do: alias_.default_params || %{}

  # Recursively merge `override` into `base`; for keys present in both where both
  # values are (non-struct) maps, merge recursively, else `override` wins.
  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, b, o -> deep_merge(b, o) end)
  end

  defp deep_merge(_base, override), do: override
end
