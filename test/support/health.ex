defmodule Airo.Test.Health do
  @moduledoc """
  Health-threshold control for tests (S24).

  A deployment only goes `:down` after `down_after_failures` consecutive failing
  observations. Most tests predate that and are about *classification* — does an
  unreachable provider read as down, does a 5xx, does a transport error — not
  about how many failures it takes. Those set the threshold to 1 so they assert
  the thing they were written to assert.

  Tests that are about the hysteresis itself set it explicitly too. Nothing
  should rely on the seeded default: a test that silently depends on it breaks
  the day an operator changes the setting's default.
  """

  alias Airo.Config

  @doc """
  Set the consecutive-failure threshold for this test.

  `1` restores the pre-S24 behaviour where a single failure marks a deployment
  down immediately.
  """
  def set_failure_threshold(n) when is_integer(n) and n >= 1 do
    {:ok, _setting} =
      Config.update_site_setting(%{
        down_after_failures: n,
        time_zone: Config.site_setting().time_zone || "America/Los_Angeles"
      })

    :ok
  end
end
