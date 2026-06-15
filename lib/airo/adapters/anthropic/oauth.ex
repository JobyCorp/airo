defmodule Airo.Adapters.Anthropic.OAuth do
  @moduledoc """
  claude-code OAuth token freshness for an Anthropic provider (DESIGN §6, §8).

  The provider's credential `Secret` holds the access token (`value`),
  `refresh_token`, and `expires_at`. `ensure_fresh/1` returns a usable access
  token, refreshing (and persisting the new tokens) when the current one is
  within the expiry buffer. The token endpoint and client id are configurable:

      config :airo, Airo.Adapters.Anthropic,
        oauth_token_url: "https://console.anthropic.com/v1/oauth/token",
        oauth_client_id: System.get_env("ANTHROPIC_OAUTH_CLIENT_ID")
  """

  alias Airo.Config
  alias Airo.Config.{Provider, Secret}

  # Refresh this many seconds before the token actually expires.
  @expiry_buffer_s 60

  @default_token_url "https://console.anthropic.com/v1/oauth/token"

  @spec ensure_fresh(Provider.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_fresh(%Provider{credential: %Secret{value: value} = secret}) when is_binary(value) do
    if fresh?(secret), do: {:ok, value}, else: refresh(secret)
  end

  def ensure_fresh(_provider), do: {:error, :no_credential}

  defp fresh?(%Secret{expires_at: nil}), do: true

  defp fresh?(%Secret{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), @expiry_buffer_s, :second)) ==
      :gt
  end

  defp refresh(%Secret{refresh_token: nil}), do: {:error, :no_refresh_token}

  defp refresh(%Secret{refresh_token: refresh_token} = secret) do
    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => client_id()
    }

    case Req.post(req(), url: token_url(), json: body) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token} = resp}} ->
        persist(secret, access_token, resp["refresh_token"] || refresh_token, resp["expires_in"])
        {:ok, access_token}

      {:ok, %Req.Response{status: status, body: resp}} ->
        {:error, {:oauth_refresh_failed, status, resp}}

      {:error, reason} ->
        {:error, {:oauth_refresh_failed, reason}}
    end
  end

  defp persist(secret, access_token, refresh_token, expires_in) do
    Config.update_secret(secret, %{
      value: access_token,
      refresh_token: refresh_token,
      expires_at: expires_at(expires_in)
    })
  end

  defp expires_at(seconds) when is_integer(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp expires_at(_), do: nil

  defp req do
    [finch: Airo.Finch, decode_json: [keys: :strings], retry: false]
    |> Keyword.merge(Application.get_env(:airo, Airo.Transport, [])[:req_options] || [])
    |> Req.new()
  end

  defp config, do: Application.get_env(:airo, Airo.Adapters.Anthropic, [])
  defp token_url, do: Keyword.get(config(), :oauth_token_url, @default_token_url)
  defp client_id, do: Keyword.get(config(), :oauth_client_id)
end
