defmodule ReplicantServer.Repo.Migrations.CreateChangeEvents do
  use Ecto.Migration

  def change do
    create table(:change_events, primary_key: false) do
      add :sequence, :bigserial, primary_key: true
      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :forward_patch, :map
      add :reverse_patch, :map
      add :applied, :boolean, null: false, default: true
      add :server_timestamp, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
    end

    create index(:change_events, [:user_id])
    create index(:change_events, [:document_id])
    create index(:change_events, [:user_id, :sequence])
  end
end
