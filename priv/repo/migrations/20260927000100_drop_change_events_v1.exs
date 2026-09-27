defmodule ReplicantServer.Repo.Migrations.DropChangeEventsV1 do
  use Ecto.Migration

  def up, do: drop(table(:change_events_v1))

  def down, do: raise(Ecto.MigrationError, message: "protocol v1 change history is not restored")
end
