defmodule ReplicantServer.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :content, :map, null: false
      add :sync_revision, :integer, null: false, default: 1
      add :content_hash, :string
      add :title, :string
      add :size_bytes, :integer
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create index(:documents, [:user_id])
    create index(:documents, [:user_id, :deleted_at])
  end
end
