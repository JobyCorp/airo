defmodule Airo.Gateway.ParamsTest do
  use ExUnit.Case, async: true

  alias Airo.Config.{Alias, Deployment, Provider}
  alias Airo.Gateway.Params

  defp layers(opts \\ []) do
    %{
      provider: %Provider{default_params: Keyword.get(opts, :provider, %{})},
      deployment: %Deployment{default_params: Keyword.get(opts, :deployment, %{})},
      alias: %Alias{default_params: Keyword.get(opts, :alias, %{})}
    }
  end

  test "request params override the layered defaults" do
    layers = layers(provider: %{"temperature" => 0.2}, alias: %{"temperature" => 0.7})
    out = Params.normalize(%{"temperature" => 0.9, "messages" => []}, layers)
    assert out["temperature"] == 0.9
  end

  test "defaults apply in precedence order provider < deployment < alias" do
    layers =
      layers(
        provider: %{"a" => 1, "b" => 1, "c" => 1},
        deployment: %{"b" => 2, "c" => 2},
        alias: %{"c" => 3}
      )

    out = Params.normalize(%{"messages" => []}, layers)
    assert %{"a" => 1, "b" => 2, "c" => 3} = out
  end

  test "unknown keys pass through untouched" do
    out = Params.normalize(%{"messages" => [], "x_custom_flag" => true}, layers())
    assert out["x_custom_flag"] == true
  end

  test "nested option bags deep-merge rather than replace" do
    layers =
      layers(deployment: %{"chat_template_kwargs" => %{"enable_thinking" => true, "keep" => 1}})

    out = Params.normalize(%{"chat_template_kwargs" => %{"enable_thinking" => false}}, layers)
    assert out["chat_template_kwargs"] == %{"enable_thinking" => false, "keep" => 1}
  end

  test "provider_params is raw passthrough at the highest precedence and is stripped as a key" do
    layers = layers(alias: %{"top_p" => 0.5})

    out =
      Params.normalize(
        %{"top_p" => 0.9, "provider_params" => %{"top_p" => 0.1, "raw_knob" => "x"}},
        layers
      )

    assert out["top_p"] == 0.1
    assert out["raw_knob"] == "x"
    refute Map.has_key?(out, "provider_params")
  end

  test "the gateway-only `route` key is dropped before dispatch" do
    out = Params.normalize(%{"messages" => [], "route" => %{"class" => "deep"}}, layers())
    refute Map.has_key?(out, "route")
  end
end
