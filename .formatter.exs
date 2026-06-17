[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phoenix_live_view],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  # JobyKit's manifest DSL (JobyKit.Manifest) is written without parens; declare
  # it so `mix format` leaves the DesignManifest alone. JobyKit doesn't export a
  # formatter config, so we list the locals here rather than via import_deps.
  locals_without_parens: [category: 2, component: 3],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
