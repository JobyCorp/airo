defmodule Airo.Adapters.Codex.OAuth do
  @moduledoc """
  ChatGPT-subscription OAuth token freshness for a Codex provider (DESIGN §6,
  §8) — the "Sign in with ChatGPT" tokens the Codex CLI uses, refreshed against
  `auth.openai.com`.

  The provider's credential `Secret` holds the access token (`value`),
  `refresh_token`, and `expires_at`. `ensure_fresh/1` returns a usable access
  token, refreshing (and persisting the new tokens) when the current one is
  within the expiry buffer. The token endpoint and client id are configurable:

      config :airo, Airo.Adapters.Codex,
        oauth_token_url: "https://auth.openai.com/oauth/token",
        oauth_client_id: "app_EMoamEEZ73f0CkXaXp7hrann"
  """

  alias Airo.Config
  alias Airo.Config.{Provider, Secret}

  # Refresh this many seconds before the token actually expires.
  @expiry_buffer_s 60

  @default_token_url "https://auth.openai.com/oauth/token"
  # OpenAI's published client id for the Codex CLI "Sign in with ChatGPT" flow.
  @default_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  # The JWT claim namespace ChatGPT account metadata lives under.
  @auth_claim "https://api.openai.com/auth"

  @spec ensure_fresh(Provider.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_fresh(%Provider{credential: %Secret{value: value} = secret}) when is_binary(value) do
    if fresh?(secret), do: {:ok, value}, else: refresh(secret)
  end

  def ensure_fresh(_provider), do: {:error, :no_credential}

  @doc """
  The ChatGPT account id carried in the access token's `#{@auth_claim}` claim.
  The Codex backend requires it as the `chatgpt-account-id` header on every
  request.
  """
  @spec account_id(String.t()) :: {:ok, String.t()} | {:error, :no_account_id}
  def account_id(access_token) do
    case claims(access_token) do
      %{@auth_claim => %{"chatgpt_account_id" => id}} when is_binary(id) -> {:ok, id}
      _ -> {:error, :no_account_id}
    end
  end

  @doc """
  Absolute expiry for a token: the response's `expires_in` when present,
  otherwise the access token's own JWT `exp` claim (the refresh/exchange
  responses don't always carry `expires_in`).
  """
  @spec expires_at(String.t(), term()) :: DateTime.t() | nil
  def expires_at(_access_token, seconds) when is_integer(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  def expires_at(access_token, _absent) do
    with %{"exp" => exp} when is_integer(exp) <- claims(access_token),
         {:ok, expiry} <- DateTime.from_unix(exp) do
      expiry
    else
      _ -> nil
    end
  end

  defp fresh?(%Secret{expires_at: nil}), do: true

  defp fresh?(%Secret{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), @expiry_buffer_s, :second)) ==
      :gt
  end

  defp refresh(%Secret{refresh_token: nil}), do: {:error, :no_refresh_token}

  defp refresh(%Secret{refresh_token: refresh_token} = secret) do
    form = [
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: client_id(),
      scope: "openid profile email"
    ]

    case Req.post(req(), url: token_url(), form: form) do
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
      expires_at: expires_at(access_token, expires_in)
    })
  end

  # Unverified claim read: we only need routing metadata (account id, exp) out
  # of a token we received from the issuer over TLS, not proof of authenticity.
  defp claims(token) when is_binary(token) do
    with [_header, payload, _sig] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      claims
    else
      _ -> nil
    end
  end

  defp claims(_token), do: nil

  @doc false
  def req do
    [finch: Airo.Finch, decode_json: [keys: :strings], retry: false]
    |> Keyword.merge(Application.get_env(:airo, Airo.Transport, [])[:req_options] || [])
    |> Req.new()
  end

  defp config, do: Application.get_env(:airo, Airo.Adapters.Codex, [])

  @doc false
  def token_url, do: Keyword.get(config(), :oauth_token_url, @default_token_url)

  @doc false
  def client_id, do: Keyword.get(config(), :oauth_client_id, @default_client_id)
end
