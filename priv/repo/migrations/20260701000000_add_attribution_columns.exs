defmodule ReplicantServer.Repo.Migrations.AddAttributionColumns do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :display_name, :string
    end

    alter table(:documents) do
      add :author_name, :string
      add :visibility, :string, null: false, default: "private"
      add :provenance, :map, null: false, default: %{}
    end

    # Existing public docs are the ones with no owner (legacy user_id IS NULL).
    # Classify them before Task 4 flips reads to be visibility-keyed.
    execute(
      "UPDATE documents SET visibility = 'public' WHERE user_id IS NULL",
      "UPDATE documents SET visibility = 'private' WHERE visibility = 'public'"
    )

    create index(:documents, [:visibility])
    create index(:documents, [:visibility, :deleted_at])
  end
end
