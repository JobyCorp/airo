defmodule Airo.Encrypted.Binary do
  @moduledoc """
  Ecto type for application-level encrypted binary columns, backed by
  `Airo.Vault`. Use for any field holding secret material at rest
  (API keys, OAuth tokens). The underlying column is `:binary`.
  """
  use Cloak.Ecto.Binary, vault: Airo.Vault
end
