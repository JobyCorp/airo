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
  intent, consumed upstream of here) and `provider_params` (folded in raw).
  Every other key — known or unknown — passes through untouched.
  """

  @gateway_only_keys ~w(route provider_params)

  @doc """
  Build the upstream request body from the client `params` and the resolved
  config layers (`:provider`, `:deployment`, `:alias`, each a schema struct with
  a `default_params` map).
  """
  @spec normalize(map(), %{provider: map(), deployment: map(), alias: map()}) :: map()
  def normalize(params, %{provider: provider, deployment: deployment, alias: alias_})
      when is_map(params) do
    provider_params = Map.get(params, "provider_params", %{})
    request = Map.drop(params, @gateway_only_keys)

    %{}
    |> deep_merge(provider.default_params || %{})
    |> deep_merge(deployment.default_params || %{})
    |> deep_merge(alias_.default_params || %{})
    |> deep_merge(request)
    |> deep_merge(provider_params)
  end

  # Recursively merge `override` into `base`; for keys present in both where both
  # values are (non-struct) maps, merge recursively, else `override` wins.
  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, b, o -> deep_merge(b, o) end)
  end

  defp deep_merge(_base, override), do: override
end
