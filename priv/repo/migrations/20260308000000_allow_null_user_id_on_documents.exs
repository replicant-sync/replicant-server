defmodule ReplicantServer.Repo.Migrations.AllowNullUserIdOnDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      modify :user_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    alter table(:change_events) do
      modify :user_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create index(:documents, [:deleted_at], name: :documents_public_idx, where: "user_id IS NULL")
  end
end
