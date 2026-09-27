defmodule ReplicantServer.V2SchemaTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Collections.{Collection, CollectionMember}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Feed.{ChangeEvent, UploadResult}

  test "change_seq hands out increasing bigints" do
    %{rows: [[a]]} = Repo.query!("SELECT nextval('change_seq')")
    %{rows: [[b]]} = Repo.query!("SELECT nextval('change_seq')")
    assert b > a
  end

  test "change_events is keyed by (scope, seq)" do
    event = %ChangeEvent{
      scope: "own:schema",
      seq: 1,
      prev_seq: 0,
      doc_id: Ecto.UUID.generate(),
      kind: "upsert"
    }

    Repo.insert!(event)
    Repo.insert!(%{event | scope: "collection:schema"})
    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(event) end
  end

  test "change_events rejects an unknown kind" do
    event = %ChangeEvent{
      scope: "own:k",
      seq: 1,
      prev_seq: 0,
      doc_id: Ecto.UUID.generate(),
      kind: "create"
    }

    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(event) end
  end

  test "the curated collection is seeded as public" do
    assert %Collection{access: "public", owner_id: nil} =
             Repo.get_by!(Collection, name: "curated")
  end

  test "documents default to writable with seq 0" do
    doc =
      Repo.insert!(%Document{id: Ecto.UUID.generate(), content: %{"a" => 1}}) |> Repo.reload!()

    assert doc.seq == 0
    refute doc.read_only
  end

  test "upload_results are keyed by (upload_id, base_hash)" do
    row = %UploadResult{
      upload_id: Ecto.UUID.generate(),
      base_hash: "",
      doc_id: Ecto.UUID.generate(),
      reply: %{"ok" => true}
    }

    Repo.insert!(row)
    Repo.insert!(%{row | base_hash: "abc"})
    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(row) end
  end

  test "collection membership is keyed by (collection, document)" do
    curated = Repo.get_by!(Collection, name: "curated")
    doc = Repo.insert!(%Document{id: Ecto.UUID.generate(), content: %{}, read_only: true})
    member = %CollectionMember{collection_id: curated.id, document_id: doc.id, added_seq: 1}
    Repo.insert!(member)
    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(member) end
  end

  test "the trim watermark starts at zero" do
    assert %{rows: [[0]]} =
             Repo.query!("SELECT trim_watermark FROM change_feed_state WHERE id = 1")
  end
end
