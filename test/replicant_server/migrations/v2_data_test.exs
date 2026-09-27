defmodule ReplicantServer.Migrations.V2DataTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents}
  alias ReplicantServer.Collections.{Collection, CollectionMember}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Migrations.V2Data

  defp legacy(attrs) do
    Repo.insert!(
      struct(
        %Document{
          id: Ecto.UUID.generate(),
          content: %{"title" => "t"},
          content_hash: "stale",
          visibility: "private"
        },
        attrs
      )
    )
  end

  defp curated_members do
    curated = Repo.get_by!(Collection, name: "curated")

    Repo.all(
      from m in CollectionMember, where: m.collection_id == ^curated.id, select: m.document_id
    )
  end

  # A legacy row whose jsonb content is not a JSON object (Ecto's :map type
  # can't load it), inserted via raw SQL to bypass the schema.
  defp legacy_nonmap_content(user_id) do
    insert_raw_content(user_id, "[\"legacy\",\"array\"]")
  end

  # A legacy row whose jsonb content is the JSON `null` literal.
  defp legacy_null_content(user_id) do
    insert_raw_content(user_id, "null")
  end

  defp insert_raw_content(user_id, json) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO documents (id, user_id, content, visibility, created_at, updated_at) VALUES ($1, $2, $3::jsonb, 'public', now(), now())",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(user_id), json]
    )

    %{id: id}
  end

  defp raw_document(id) do
    %{rows: [[seq, read_only, content_hash, deleted_at]]} =
      Repo.query!(
        "SELECT seq, read_only, content_hash, deleted_at FROM documents WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    %{seq: seq, read_only: read_only, content_hash: content_hash, deleted_at: deleted_at}
  end

  setup do
    {:ok, author} = Accounts.get_or_create_user("v2-author@example.com")

    docs = %{
      owned:
        legacy(user_id: author.id, visibility: "public", content: %{"title" => "Owned public"}),
      ownerless: legacy(visibility: "public", content: %{"title" => "Legacy public"}),
      deleted: legacy(user_id: author.id, visibility: "public", deleted_at: DateTime.utc_now()),
      private: legacy(user_id: author.id),
      null_hash:
        legacy(
          user_id: author.id,
          visibility: "public",
          content_hash: nil,
          content: %{"title" => "No hash"}
        ),
      odd_float:
        legacy(
          user_id: author.id,
          visibility: "public",
          content: %{"title" => "Odd float", "value" => 5.0}
        ),
      nonmap: legacy_nonmap_content(author.id),
      jsonb_null: legacy_null_content(author.id)
    }

    count_before = Repo.aggregate(Document, :count)
    :ok = V2Data.run(Repo)
    docs |> Map.put(:author, author) |> Map.put(:count_before, count_before)
  end

  test "an owned public document becomes a publication in place without a source copy",
       %{author: author, owned: owned, count_before: count_before} do
    pub = Repo.get!(Document, owned.id)
    assert pub.read_only
    assert is_nil(pub.user_id)
    assert pub.author_id == author.id
    assert is_nil(pub.source_doc_id)
    assert is_nil(pub.source_revision)
    assert Repo.aggregate(Document, :count) == count_before
  end

  test "an ownerless public document becomes an authorless publication without a source", %{
    ownerless: d
  } do
    pub = Repo.get!(Document, d.id)
    assert pub.read_only
    assert is_nil(pub.author_id)
    assert is_nil(pub.source_doc_id)
  end

  test "curated holds every live publication", %{
    owned: owned,
    ownerless: ownerless,
    deleted: deleted,
    null_hash: null_hash,
    odd_float: odd_float
  } do
    members = curated_members()
    assert Enum.sort(members) == Enum.sort([owned.id, ownerless.id, null_hash.id, odd_float.id])
    assert Repo.get!(Document, deleted.id).read_only
  end

  test "non-object jsonb content is quarantined instead of curated or hashed", %{
    nonmap: nonmap,
    jsonb_null: jsonb_null
  } do
    for id <- [nonmap.id, jsonb_null.id] do
      row = raw_document(id)
      refute is_nil(row.deleted_at)
      assert is_nil(row.content_hash)
      assert row.seq > 0
      refute id in curated_members()
    end
  end

  test "every live document gets a seq and a recomputed non-nil hash", %{
    nonmap: nonmap,
    jsonb_null: jsonb_null
  } do
    excluded = [nonmap.id, jsonb_null.id]

    for doc <- Repo.all(from d in Document, where: d.id not in ^excluded and is_nil(d.deleted_at)) do
      assert doc.seq > 0
      refute is_nil(doc.content_hash)
      assert doc.content_hash == Documents.compute_hash(doc.content)
    end
  end

  test "legacy odd/missing data still ends with a recomputed hash and a seq",
       %{null_hash: null_hash, odd_float: odd_float} do
    for id <- [null_hash.id, odd_float.id] do
      doc = Repo.get!(Document, id)
      assert doc.seq > 0
      assert doc.read_only
      refute is_nil(doc.content_hash)
      assert doc.content_hash == Documents.compute_hash(doc.content)
    end
  end

  test "private documents stay private and owned", %{private: p} do
    doc = Repo.get!(Document, p.id)
    refute doc.read_only
    assert doc.user_id == p.user_id
  end

  test "re-running changes nothing", %{nonmap: nonmap, jsonb_null: jsonb_null} do
    excluded = [nonmap.id, jsonb_null.id]
    query = from d in Document, where: d.id not in ^excluded, order_by: d.id
    before = Repo.all(query)
    before_raw = Enum.map(excluded, &raw_document/1)

    assert :ok = V2Data.run(Repo)

    assert Repo.all(query) == before
    assert Enum.map(excluded, &raw_document/1) == before_raw
  end

  test "re-running after a v2 publication exists does not curate it", %{author: author} do
    late_pub =
      legacy(
        user_id: nil,
        author_id: author.id,
        visibility: "public",
        read_only: true,
        seq: 999_999,
        content: %{"title" => "Published via v2"}
      )

    assert :ok = V2Data.run(Repo)
    refute late_pub.id in curated_members()
  end
end
