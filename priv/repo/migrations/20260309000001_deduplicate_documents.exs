defmodule ReplicantServer.Repo.Migrations.DeduplicateDocuments do
  use Ecto.Migration

  def up do
    execute """
    UPDATE documents SET deleted_at = NOW()
    WHERE id IN (
      SELECT d.id FROM documents d
      INNER JOIN (
        SELECT user_id, content_hash, MIN(created_at) as min_created
        FROM documents
        WHERE deleted_at IS NULL AND content_hash IS NOT NULL
        GROUP BY user_id, content_hash
        HAVING COUNT(*) > 1
      ) dupes ON d.user_id IS NOT DISTINCT FROM dupes.user_id
        AND d.content_hash = dupes.content_hash
        AND d.created_at > dupes.min_created
        AND d.deleted_at IS NULL
    )
    """
  end

  def down do
    # Cannot reliably reverse soft-delete deduplication
    :ok
  end
end
