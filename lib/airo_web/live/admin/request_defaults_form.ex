defmodule AiroWeb.Admin.RequestDefaultsForm do
  @moduledoc """
  Shared form plumbing for the request-defaults section on the provider,
  deployment, and alias editors — the three `default_params` merge layers of
  `Airo.Gateway.Params`.

  Same contract as the agent config modal's launch profile: the form owns a
  few first-class sampler keys, and everything else a saved params bag carries
  rides in the advanced JSON editor verbatim. `prefill/1` splits a saved map
  into form state; `refresh/1` rebuilds it from in-flight form params;
  `fold/1` folds the submitted `dp_*` fields back into a `"default_params"`
  map on the changeset params.
  """

  @owned_keys ~w(temperature top_p presence_penalty frequency_penalty)

  @doc "Sampler keys the form owns as first-class fields (in display order)."
  def owned_keys, do: @owned_keys

  @doc "Form state (`%{values:, json:, error:}`) for a saved default_params map."
  def prefill(params) when is_map(params) do
    values = Map.new(@owned_keys, fn key -> {key, stringify(params[key])} end)

    %{values: values, json: encode_rest(Map.drop(params, @owned_keys)), error: nil}
  end

  def prefill(_params), do: prefill(%{})

  @doc """
  Form state from in-flight form params (validate) — keeps what the operator
  typed and surfaces a JSON parse error live.
  """
  def refresh(form_params) do
    values = Map.new(@owned_keys, fn key -> {key, form_params["dp_#{key}"] || ""} end)
    json = form_params["dp_json"] || ""

    %{values: values, json: json, error: json_error(json)}
  end

  @doc """
  Fold the section's `dp_*` fields into `params["default_params"]`.

  First-class fields win over the same key typed in the JSON, mirroring how
  the agent modal's form fields override its launch JSON. Returns
  `{:error, message}` when the JSON doesn't parse — keep the form open and
  show the message instead of saving.
  """
  def fold(form_params) do
    with {:ok, rest} <- decode(form_params["dp_json"]) do
      owned =
        for key <- @owned_keys,
            value = parse_number(form_params["dp_#{key}"]),
            not is_nil(value),
            into: %{},
            do: {key, value}

      params =
        form_params
        |> Map.drop(["dp_json" | Enum.map(@owned_keys, &"dp_#{&1}")])
        |> Map.put("default_params", rest |> Map.drop(@owned_keys) |> Map.merge(owned))

      {:ok, params}
    end
  end

  @doc "Inline validation message for the JSON editor, or nil when it parses."
  def json_error(json) do
    case decode(json) do
      {:ok, _map} -> nil
      {:error, message} -> message
    end
  end

  defp decode(json) when json in [nil, ""], do: {:ok, %{}}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "must be a JSON object ({…})"}
      {:error, %Jason.DecodeError{position: pos}} -> {:error, "invalid JSON at character #{pos}"}
    end
  end

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_number(_value), do: nil

  defp stringify(nil), do: ""
  defp stringify(value), do: to_string(value)

  defp encode_rest(rest) when rest == %{}, do: ""
  defp encode_rest(rest), do: Jason.encode!(rest, pretty: true)
end
