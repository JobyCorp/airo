defmodule Airo.Gateway.VisionTest do
  use ExUnit.Case, async: true

  alias Airo.Gateway.Vision

  defp image_message,
    do: %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => "describe"},
        %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}}
      ]
    }

  defp text_message, do: %{"role" => "user", "content" => "hello"}

  test "detects an image_url content part" do
    assert Vision.requires_vision?(%{"messages" => [image_message()]})
  end

  test "is false for plain text messages" do
    refute Vision.requires_vision?(%{"messages" => [text_message()]})
  end

  test "is false with no messages" do
    refute Vision.requires_vision?(%{})
    refute Vision.requires_vision?(%{"input" => "x"})
  end

  test "an explicit route.vision overrides auto-detection" do
    refute Vision.requires_vision?(%{"messages" => [image_message()], "route" => %{"vision" => false}})
    assert Vision.requires_vision?(%{"messages" => [text_message()], "route" => %{"vision" => true}})
  end
end
