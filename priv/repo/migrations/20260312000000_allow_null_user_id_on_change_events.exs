defmodule ReplicantServer.Repo.Migrations.AllowNullUserIdOnChangeEvents do
  use Ecto.Migration

  def change do
    alter table(:change_events) do
      modify :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: true,
        from: {references(:users, type: :binary_id, on_delete: :delete_all), null: false}
    end
  end
end
