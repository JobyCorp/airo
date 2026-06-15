defmodule Airo.Vault do
  @moduledoc """
  Cloak vault for Airo's secret material.

  Ciphers are configured per-environment under `config :airo, Airo.Vault`.
  The vault must be started (see `Airo.Application`) before any encrypted
  Ecto type reads or writes; encrypted columns route their crypto through here.

  See `Airo.Encrypted.Binary` for the Ecto type that uses this vault.
  """
  use Cloak.Vault, otp_app: :airo
end
