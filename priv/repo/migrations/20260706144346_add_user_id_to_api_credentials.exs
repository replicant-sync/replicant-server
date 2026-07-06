defmodule ReplicantServer.Repo.Migrations.AddUserIdToApiCredentials do
  use Ecto.Migration

  def change do
    alter table(:api_credentials) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    create index(:api_credentials, [:user_id])
  end
end
