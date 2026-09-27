defmodule ReplicantServer.Repo.Migrations.V2PublicationsData do
  use Ecto.Migration

  def up, do: ReplicantServer.Migrations.V2Data.run(repo())

  def down,
    do:
      raise(Ecto.MigrationError,
        message: "publications are not converted back to public documents"
      )
end
