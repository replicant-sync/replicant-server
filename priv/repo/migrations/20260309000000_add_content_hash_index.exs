defmodule ReplicantServer.Repo.Migrations.AddContentHashIndex do
  use Ecto.Migration

  def change do
    create index(:documents, [:user_id, :content_hash],
      where: "deleted_at IS NULL",
      name: :documents_user_content_hash_index
    )

    create index(:documents, [:content_hash],
      where: "user_id IS NULL AND deleted_at IS NULL",
      name: :documents_public_content_hash_index
    )
  end
end
