defmodule ReplicantServer.Migrations.V2Data do
  @moduledoc """
  Protocol v2 data migration: public documents become read-only publications
  in place (the former owner becomes `author_id`; no private source copy is
  made), every live publication joins `curated`, every document gets a feed
  seq, and content hashes are recomputed. Safe to re-run. No change events are
  backfilled: v2 clients start from a snapshot.
  """

  alias ReplicantServer.Documents

  @publish_owned """
  UPDATE documents
  SET author_id = user_id, user_id = NULL, read_only = true,
      source_doc_id = NULL, source_revision = NULL, updated_at = now()
  WHERE visibility = 'public' AND user_id IS NOT NULL AND NOT read_only AND deleted_at IS NULL
  """

  @publish_deleted_owned """
  UPDATE documents
  SET author_id = user_id, user_id = NULL, read_only = true, updated_at = now()
  WHERE visibility = 'public' AND user_id IS NOT NULL AND NOT read_only AND deleted_at IS NOT NULL
  """

  @publish_ownerless """
  UPDATE documents SET read_only = true, updated_at = now()
  WHERE visibility = 'public' AND user_id IS NULL AND NOT read_only
  """

  # Only seq-less documents are eligible: an already-seq'd document was
  # published through the live v2 publish path and must not be re-curated.
  @seed_curated """
  INSERT INTO collection_members (collection_id, document_id, added_seq)
  SELECT c.id, d.id, 0
  FROM documents d CROSS JOIN collections c
  WHERE c.name = 'curated' AND d.read_only AND d.deleted_at IS NULL AND d.seq = 0
  ON CONFLICT DO NOTHING
  """

  @assign_seqs "UPDATE documents SET seq = nextval('change_seq') WHERE seq = 0"

  def run(repo) do
    for sql <- [
          @publish_owned,
          @publish_deleted_owned,
          @publish_ownerless,
          @seed_curated,
          @assign_seqs
        ],
        do: repo.query!(sql)

    rehash(repo)
    :ok
  end

  defp rehash(repo) do
    %{rows: rows} = repo.query!("SELECT id, content, content_hash FROM documents")

    Enum.each(rows, fn [id, content, stored] ->
      hash = Documents.compute_hash(content)

      if hash != stored,
        do: repo.query!("UPDATE documents SET content_hash = $1 WHERE id = $2", [hash, id])
    end)
  end
end
