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

  # Bypasses Document's :map-typed content field to insert a legacy row whose
  # jsonb content is not a JSON object, the way an old client bug might have.
  # Ecto's :map type refuses to load such a row, so this (and the assertions
  # against it) stay on raw SQL rather than `Repo.get!/2`.
  defp legacy_nonmap_content(user_id) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO documents (id, user_id, content, visibility, created_at, updated_at) VALUES ($1, $2, $3::jsonb, 'public', now(), now())",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(user_id), "[\"legacy\",\"array\"]"]
    )

    %{id: id}
  end

  defp raw_document(id) do
    %{rows: [[seq, read_only, content_hash]]} =
      Repo.query!("SELECT seq, read_only, content_hash FROM documents WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    %{seq: seq, read_only: read_only, content_hash: content_hash}
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
      nonmap: legacy_nonmap_content(author.id)
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
    odd_float: odd_float,
    nonmap: nonmap
  } do
    members = curated_members()

    assert Enum.sort(members) ==
             Enum.sort([owned.id, ownerless.id, null_hash.id, odd_float.id, nonmap.id])

    assert Repo.get!(Document, deleted.id).read_only
  end

  test "every document gets a seq and a recomputed hash", %{nonmap: nonmap} do
    for doc <- Repo.all(from d in Document, where: d.id != ^nonmap.id) do
      assert doc.seq > 0
      assert doc.content_hash == Documents.compute_hash(doc.content)
    end
  end

  test "legacy odd/missing data still ends with a recomputed hash and a seq",
       %{null_hash: null_hash, odd_float: odd_float, nonmap: nonmap} do
    for id <- [null_hash.id, odd_float.id] do
      doc = Repo.get!(Document, id)
      assert doc.seq > 0
      assert doc.read_only
      refute is_nil(doc.content_hash)
      assert doc.content_hash == Documents.compute_hash(doc.content)
    end

    # Non-map jsonb content has no canonical hash by definition (and Ecto's
    # :map field can't even load it), but the migration must still assign it
    # a seq without crashing.
    nonmap_row = raw_document(nonmap.id)
    assert nonmap_row.seq > 0
    assert nonmap_row.read_only
    assert is_nil(nonmap_row.content_hash)
  end

  test "private documents stay private and owned", %{private: p} do
    doc = Repo.get!(Document, p.id)
    refute doc.read_only
    assert doc.user_id == p.user_id
  end

  test "re-running changes nothing", %{nonmap: nonmap} do
    query = from d in Document, where: d.id != ^nonmap.id, order_by: d.id
    before = Repo.all(query)
    before_nonmap = raw_document(nonmap.id)

    assert :ok = V2Data.run(Repo)

    assert Repo.all(query) == before
    assert raw_document(nonmap.id) == before_nonmap
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
