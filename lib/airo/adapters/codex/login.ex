defmodule Airo.Adapters.Codex.Login do
  @moduledoc """
  PKCE "Sign in with ChatGPT" flow for a Codex provider.

  Airo can't receive the OAuth redirect — the client id only allows
  `http://localhost:1455/auth/callback`, the address the Codex CLI listens on —
  so the flow is paste-back: `start/0` builds the authorize URL plus the PKCE
  verifier, the operator signs in in their browser, and pastes the resulting
  callback URL (or bare `code`) into the provider page; `exchange/2` then
  trades it for tokens. Endpoints and client id are configurable:

      config :airo, Airo.Adapters.Codex,
        oauth_authorize_url: "https://auth.openai.com/oauth/authorize",
        oauth_redirect_uri: "http://localhost:1455/auth/callback"
  """

  alias Airo.Adapters.Codex.OAuth

  @default_authorize_url "https://auth.openai.com/oauth/authorize"
  @default_redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access"

  @doc """
  Begin a sign-in: the URL the operator opens, plus the PKCE `verifier` (and
  `state`) the caller must hold on to for `exchange/2`.
  """
  @spec start() :: %{url: String.t(), verifier: String.t(), state: String.t()}
  def start do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)
    state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => OAuth.client_id(),
        "redirect_uri" => redirect_uri(),
        "scope" => @scope,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "id_token_add_organizations" => "true",
        "state" => state
      })

    %{url: authorize_url() <> "?" <> query, verifier: verifier, state: state}
  end

  @doc """
  Trade the pasted callback (full redirect URL, query string, or bare code)
  plus the PKCE verifier for tokens, returned as the fields a credential
  `Secret` persists.
  """
  @spec exchange(String.t(), String.t()) ::
          {:ok,
           %{
             value: String.t(),
             refresh_token: String.t() | nil,
             expires_at: DateTime.t() | nil
           }}
          | {:error, term()}
  def exchange(callback, verifier) when is_binary(callback) and is_binary(verifier) do
    with {:ok, code} <- code_from(callback) do
      form = [
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri(),
        client_id: OAuth.client_id(),
        code_verifier: verifier
      ]

      case Req.post(OAuth.req(), url: OAuth.token_url(), form: form) do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => access} = resp}} ->
          {:ok,
           %{
             value: access,
             refresh_token: resp["refresh_token"],
             expires_at: OAuth.expires_at(access, resp["expires_in"])
           }}

        {:ok, %Req.Response{status: status, body: resp}} ->
          {:error, {:oauth_exchange_failed, status, resp}}

        {:error, reason} ->
          {:error, {:oauth_exchange_failed, reason}}
      end
    end
  end

  # Accept whatever the operator pasted: the full localhost callback URL, just
  # its query string, or the bare authorization code.
  defp code_from(input) do
    input = String.trim(input)
    query = URI.parse(input).query || input

    case URI.decode_query(query) do
      %{"code" => code} when is_binary(code) and code != "" ->
        {:ok, code}

      _ ->
        if input != "" and not String.contains?(input, "="),
          do: {:ok, input},
          else: {:error, :no_code}
    end
  end

  defp config, do: Application.get_env(:airo, Airo.Adapters.Codex, [])
  defp authorize_url, do: Keyword.get(config(), :oauth_authorize_url, @default_authorize_url)
  defp redirect_uri, do: Keyword.get(config(), :oauth_redirect_uri, @default_redirect_uri)
end
