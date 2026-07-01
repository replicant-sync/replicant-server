defmodule Mix.Tasks.Replicant.BackfillFactory do
  @shortdoc "Mint factory contributors and backfill preset attribution"
  @moduledoc """
  Reads the canonical preset JSONs and upserts each as an owned public document.

      mix replicant.backfill_factory --json-dir ../../node-audio/entonal-common/database/public-tunings

  Options:
    --json-dir  (required) directory of preset *.json files
    --config    path to the contributor config (default: priv/repo/factory_contributors.exs)
  """
  use Mix.Task

  alias ReplicantServer.Factory.{Backfill, Contributors}

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [json_dir: :string, config: :string])

    json_dir = opts[:json_dir] || Mix.raise("--json-dir is required")
    config_path = opts[:config] || "priv/repo/factory_contributors.exs"

    Mix.Task.run("app.start")

    case Contributors.load(config_path) do
      {:ok, config} ->
        {:ok, stats} = Backfill.run(json_dir, config)
        Mix.shell().info("Backfill complete: #{inspect(stats)}")

      {:error, reason} ->
        Mix.raise("Could not load contributor config at #{config_path}: #{inspect(reason)}")
    end
  end
end
