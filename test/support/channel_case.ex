defmodule AiroWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channels. Brings in `Phoenix.ChannelTest` plus the Ecto
  sandbox (shared mode, since the channel runs in its own process).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import AiroWeb.ChannelCase

      @endpoint AiroWeb.Endpoint
    end
  end

  setup tags do
    Airo.DataCase.setup_sandbox(tags)
    :ok
  end
end
