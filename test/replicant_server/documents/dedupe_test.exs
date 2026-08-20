defmodule ReplicantServer.Documents.DedupeTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Accounts
  alias ReplicantServer.Documents
  alias ReplicantServer.Documents.{Dedupe, Document}
  alias ReplicantServer.Repo

  defp insert_doc(user_id, content, opts) do
    {:ok, doc} =
      %Document{}
      |> Document.create_changeset(%{
        id: opts[:id] || Ecto.UUID.generate(),
        user_id: user_id,
        content: content,
        content_hash: Documents.compute_hash(content),
        title: content["title"],
        visibility: opts[:visibility] || "private"
      })
      |> Repo.insert()

    case opts[:created_at] do
      nil ->
        doc

      created_at ->
        Repo.update_all(from(d in Document, where: d.id == ^doc.id),
          set: [created_at: created_at]
        )

        Repo.get!(Document, doc.id)
    end
  end

  setup do
    {:ok, user} = Accounts.get_or_create_user("dedupe@example.com")
    %{user: user}
  end

  test "hash pass keeps the oldest and tombstones the rest", %{user: user} do
    content = %{"type" => "tuning", "title" => "Dup", "pitches" => ["1"]}

    old = insert_doc(user.id, content, created_at: ~U[2026-01-01 00:00:00.000000Z])
    new1 = insert_doc(user.id, content, created_at: ~U[2026-01-02 00:00:00.000000Z])
    new2 = insert_doc(user.id, content, created_at: ~U[2026-01-03 00:00:00.000000Z])

    assert {:ok, report} = Dedupe.run(execute: true, user: user.id)

    assert report.users_scanned == 1
    assert report.hash_groups == 1
    assert report.semantic_groups == 0
    assert report.affected_count == 2

    remaining = Documents.list_user_documents(user.id)
    assert [kept] = remaining
    assert kept.id == old.id

    assert Documents.get_user_document(user.id, old.id)

    for deleted <- [new1, new2] do
      doc = Repo.get!(Document, deleted.id)
      assert doc.deleted_at != nil
    end
  end

  test "semantic pass groups differing serializations of the same tuning", %{user: user} do
    a =
      insert_doc(
        user.id,
        %{"type" => "tuning", "title" => "12 TET", "period" => "2/1", "pitches" => ["1", "2"]},
        created_at: ~U[2026-01-01 00:00:00.000000Z]
      )

    b =
      insert_doc(
        user.id,
        %{
          "type" => "tuning",
          "title" => "12 TET",
          "period" => "2/1",
          "pitches" => ["1", "2"],
          "description" => "different metadata, same identity"
        },
        created_at: ~U[2026-01-02 00:00:00.000000Z]
      )

    refute a.content_hash == b.content_hash

    assert {:ok, dry} = Dedupe.run(execute: false, semantic: true)
    assert dry.hash_groups == 0
    assert dry.semantic_groups == 1
    assert dry.affected_count == 1

    assert {:ok, report} = Dedupe.run(execute: true, semantic: true)
    assert report.semantic_groups == 1
    assert report.affected_count == 1

    remaining = Documents.list_user_documents(user.id)
    assert [kept] = remaining
    assert kept.id == a.id
    assert Repo.get!(Document, b.id).deleted_at != nil
  end

  test "semantic grouping requires the --semantic flag", %{user: user} do
    insert_doc(
      user.id,
      %{"type" => "tuning", "title" => "12 TET", "period" => "2/1", "pitches" => ["1"]},
      created_at: ~U[2026-01-01 00:00:00.000000Z]
    )

    insert_doc(
      user.id,
      %{
        "type" => "tuning",
        "title" => "12 TET",
        "period" => "2/1",
        "pitches" => ["1"],
        "extra" => true
      },
      created_at: ~U[2026-01-02 00:00:00.000000Z]
    )

    assert {:ok, report} = Dedupe.run(execute: false)
    assert report.groups == []
  end

  test "public and curated documents are never touched" do
    content = %{"type" => "tuning", "title" => "Preset", "pitches" => ["1"]}

    {:ok, pub1} = Documents.create_public_document(%{content: content})

    {:ok, dup} =
      %Document{}
      |> Document.create_changeset(%{
        id: Ecto.UUID.generate(),
        user_id: nil,
        content: content,
        content_hash: pub1.content_hash,
        title: content["title"],
        visibility: "public"
      })
      |> Repo.insert()

    assert {:ok, report} = Dedupe.run(execute: true, semantic: true)
    assert report.groups == []
    assert report.affected_count == 0

    assert Documents.get_public_document(pub1.id)
    assert Documents.get_public_document(dup.id)
  end

  test "an owned document marked public is excluded even though it has a user_id", %{user: user} do
    content = %{"type" => "tuning", "title" => "Owned public", "pitches" => ["1"]}

    keep = insert_doc(user.id, content, created_at: ~U[2026-01-01 00:00:00.000000Z])

    owned_public =
      insert_doc(user.id, content,
        created_at: ~U[2026-01-02 00:00:00.000000Z],
        visibility: "public"
      )

    assert {:ok, report} = Dedupe.run(execute: true)
    assert report.groups == []

    assert Documents.get_user_document(user.id, keep.id)
    assert Repo.get!(Document, owned_public.id).deleted_at == nil
  end

  test "dry run changes nothing", %{user: user} do
    content = %{"type" => "tuning", "title" => "Dup", "pitches" => ["1"]}

    insert_doc(user.id, content, created_at: ~U[2026-01-01 00:00:00.000000Z])
    insert_doc(user.id, content, created_at: ~U[2026-01-02 00:00:00.000000Z])

    assert {:ok, report} = Dedupe.run(execute: false)
    assert report.affected_count == 1
    assert length(Documents.list_user_documents(user.id)) == 2
  end

  test "--user filter restricts the scan to one user by id or email", %{user: user} do
    other_content = %{"type" => "tuning", "title" => "Other's dup", "pitches" => ["1"]}
    {:ok, other_user} = Accounts.get_or_create_user("other@example.com")

    content = %{"type" => "tuning", "title" => "Dup", "pitches" => ["1"]}
    insert_doc(user.id, content, created_at: ~U[2026-01-01 00:00:00.000000Z])
    insert_doc(user.id, content, created_at: ~U[2026-01-02 00:00:00.000000Z])

    insert_doc(other_user.id, other_content, created_at: ~U[2026-01-01 00:00:00.000000Z])
    insert_doc(other_user.id, other_content, created_at: ~U[2026-01-02 00:00:00.000000Z])

    assert {:ok, by_id} = Dedupe.run(execute: false, user: user.id)
    assert by_id.users_scanned == 1
    assert by_id.affected_count == 1

    assert {:ok, by_email} = Dedupe.run(execute: false, user: "dedupe@example.com")
    assert by_email.affected_count == 1

    assert {:error, :user_not_found} = Dedupe.run(execute: false, user: "nobody@example.com")
  end
end
