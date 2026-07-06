defmodule ReplicantServer.Repo.Migrations.CreateEnrollmentTokens do
  use Ecto.Migration

  def change do
    create table(:enrollment_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:enrollment_tokens, [:token_hash])
    create index(:enrollment_tokens, [:user_id])
  end
end
