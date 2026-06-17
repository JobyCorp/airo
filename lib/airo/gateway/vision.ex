defmodule Airo.Gateway.Vision do
  @moduledoc """
  Detects whether a chat request needs a vision-capable deployment. OpenAI
  multimodal requests carry `image_url` parts in `messages[].content`, so a
  request with any image part requires the `:vision` resource capability — the
  gateway uses this to narrow routing to deployments that can actually see
  images, with `route.vision` as an explicit override.
  """

  @doc """
  True when the request carries image content, or `route.vision` forces it.
  An explicit `route.vision` (true/false) always wins over auto-detection.
  """
  @spec requires_vision?(map()) :: boolean()
  def requires_vision?(params) when is_map(params) do
    case get_in(params, ["route", "vision"]) do
      flag when is_boolean(flag) -> flag
      _ -> has_image?(params)
    end
  end

  defp has_image?(%{"messages" => messages}) when is_list(messages),
    do: Enum.any?(messages, &image_message?/1)

  defp has_image?(_), do: false

  defp image_message?(%{"content" => content}) when is_list(content),
    do: Enum.any?(content, &image_part?/1)

  defp image_message?(_), do: false

  defp image_part?(%{"type" => "image_url"}), do: true
  defp image_part?(_), do: false
end
