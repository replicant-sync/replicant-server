defmodule ReplicantServer.Repo.Migrations.CreateApiCredentials do
  use Ecto.Migration

  def change do
    create table(:api_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :api_key, :string, null: false
      add :secret, :string, null: false
      add :name, :string, null: false
      add :last_used_at, :utc_datetime_usec
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
    end

    create unique_index(:api_credentials, [:api_key])
  end
end
