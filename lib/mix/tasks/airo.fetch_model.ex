defmodule Mix.Tasks.Airo.FetchModel do
  @shortdoc "Fetch + checksum-verify a local ONNX routing model into priv/models/"

  @moduledoc """
  Fetch a local ONNX routing model (S15) into `priv/models/<name>/` and verify its
  checksums. Model binaries are **gitignored** and never committed — this task is
  the reproducible way to put them in place (locally and on the build host before
  `mix release`, so they ship in the tarball).

      mix airo.fetch_model nvidia-prompt-task-complexity --from DIR
      mix airo.fetch_model nvidia-prompt-task-complexity            # uses the manifest url

  Options:
    * `--from DIR`  copy `model.onnx` + `tokenizer.json` from a local directory
    * `--force`     re-fetch even if present and already verified

  The manifest below is the committed record of each model's HF revision, expected
  sha256s, and output contract. Sources: set `--from` (local) or `:url` (HTTPS).
  """

  use Mix.Task

  @models %{
    "nvidia-prompt-task-complexity" => %{
      source: "nvidia/prompt-task-and-complexity-classifier",
      revision: "fea1121511eafabaf7dd6fc66863dcb04f74defb",
      # Set to an HTTPS base URL once hosted; until then pass --from.
      url: nil,
      files: %{
        "model.onnx" => "1e77d482ba11ce0c7e0a2e33efbc5d26076d061bb88d5400585cc18d02b208e5",
        "tokenizer.json" => "4b4f60231058db4b5794e7b124bb7945bc8ade6719282de4d2e0372ee527b929"
      },
      # Output contract — consumed by Airo.Routing.LocalClassifier; recorded here
      # so a re-export that changes shapes/order is caught against this record.
      contract: %{
        inputs: ["input_ids", "attention_mask"],
        outputs: %{"complexity_dims" => 6, "overall_complexity" => 1, "task_type_probs" => 11},
        # complexity_dims column order (drives the score weighting):
        dims:
          ~w(creativity reasoning constraint domain_knowledge contextual_knowledge num_few_shots),
        # task_type_probs idx -> label (config.task_type_map; idx 11 "Unknown" is
        # dropped by the [:11] slice — valid only because it is the last class).
        task_type_map: [
          "Brainstorming",
          "Chatbot",
          "Classification",
          "Closed QA",
          "Code Generation",
          "Extraction",
          "Open QA",
          "Other",
          "Rewrite",
          "Summarization",
          "Text Generation"
        ]
      }
    }
  }

  @chunk 2_097_152

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [from: :string, force: :boolean])

    name = List.first(args) || Mix.raise(usage())

    spec =
      Map.get(@models, name) || Mix.raise("unknown model #{inspect(name)}; known: #{known()}")

    dest = Path.join([File.cwd!(), "priv", "models", name])
    File.mkdir_p!(dest)

    Enum.each(spec.files, fn {file, sha} ->
      fetch_file(file, sha, dest, spec, opts)
    end)

    Mix.shell().info("✓ #{name} ready at priv/models/#{name} (revision #{spec.revision})")
  end

  defp fetch_file(file, sha, dest, spec, opts) do
    dst = Path.join(dest, file)

    cond do
      File.exists?(dst) and !opts[:force] and sha256(dst) == sha ->
        Mix.shell().info("• #{file} present + verified")

      opts[:from] ->
        place(file, Path.join(opts[:from], file), dst, sha, &copy/2)

      spec.url ->
        place(file, spec.url <> "/" <> file, dst, sha, &download/2)

      true ->
        Mix.raise("no source for #{file}: pass --from DIR (or set :url in the manifest)")
    end
  end

  defp place(file, src, dst, sha, transfer) do
    Mix.shell().info("• fetching #{file} …")
    transfer.(src, dst)
    actual = sha256(dst)

    if actual == sha do
      Mix.shell().info("  ✓ #{file} checksum OK")
    else
      File.rm(dst)
      Mix.raise("checksum mismatch for #{file}\n  expected #{sha}\n  got      #{actual}")
    end
  end

  defp copy(src, dst) do
    File.exists?(src) || Mix.raise("source not found: #{src}")
    File.cp!(src, dst)
  end

  defp download(url, dst) do
    Req.get!(url, into: File.stream!(dst), redirect: true)
  rescue
    e -> Mix.raise("download failed for #{url}: #{Exception.message(e)}")
  end

  defp sha256(path) do
    path
    |> File.stream!(@chunk)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp known, do: @models |> Map.keys() |> Enum.join(", ")
  defp usage, do: "usage: mix airo.fetch_model <name> [--from DIR] [--force]\nknown: #{known()}"
end
