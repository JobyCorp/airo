defmodule AiroWeb.VoicesController do
  @moduledoc """
  `GET /v1/audio/voices` — the TTS voices callable by the client key, aggregated
  live across speech providers (`Airo.Voices`). Optional `?model=<id>` restricts
  to a single model. OpenAI list shape, mirroring `GET /v1/models`.
  """
  use AiroWeb, :controller

  alias Airo.Voices

  def index(conn, params) do
    data = Voices.list(client_key: conn.assigns.client_key, model: params["model"])
    json(conn, %{"object" => "list", "data" => data})
  end
end
