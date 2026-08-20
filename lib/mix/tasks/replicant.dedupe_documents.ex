defmodule Mix.Tasks.Replicant.DedupeDocuments do
  @shortdoc "Remove duplicate per-user documents (re-runnable)"
  @moduledoc """
  Finds duplicate per-user documents and soft-deletes all but the oldest,
  producing normal sync tombstones. Public/curated documents are never
  touched. Safe to re-run: once duplicates are gone, subsequent runs find
  nothing to do.

      mix replicant.dedupe_documents
      mix replicant.dedupe_documents --execute
      mix replicant.dedupe_documents --execute --semantic
      mix replicant.dedupe_documents --user user@example.com

  Options:
    --execute   apply deletions (default is a dry run that changes nothing)
    --semantic  also group "tuning" documents by title/period/pitches, not
                just byte-identical content
    --user      restrict to one user, by id or email
  """

  use Mix.Task

  alias ReplicantServer.Documents.Dedupe

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [execute: :boolean, semantic: :boolean, user: :string])

    Mix.Task.run("app.start")

    case Dedupe.run(
           execute: opts[:execute] || false,
           semantic: opts[:semantic] || false,
           user: opts[:user]
         ) do
      {:ok, report} -> print_report(report)
      {:error, :user_not_found} -> Mix.raise("No user found for --user #{opts[:user]}")
    end
  end

  defp print_report(report) do
    mode = if report.execute, do: "EXECUTE", else: "DRY RUN"
    verb = if report.execute, do: "deleted", else: "would delete"

    Mix.shell().info(
      "\nDedupe documents (#{mode}#{if report.semantic, do: " + semantic", else: ""})\n"
    )

    Enum.each(report.groups, fn group ->
      Mix.shell().info("user #{group.user_email} (#{group.user_id}) [#{group.pass}]")
      Mix.shell().info("  keep:    #{group.kept.id}  #{inspect(group.kept.title)}")

      Enum.each(group.to_delete, fn doc ->
        Mix.shell().info("  #{verb}: #{doc.id}  #{inspect(doc.title)}")
      end)
    end)

    Mix.shell().info("""

    Summary
    -------
    users scanned:    #{report.users_scanned}
    duplicate groups: #{length(report.groups)} (hash: #{report.hash_groups}, semantic: #{report.semantic_groups})
    documents #{verb}: #{report.affected_count}
    """)
  end
end
