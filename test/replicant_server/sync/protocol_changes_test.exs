defmodule ReplicantServer.Sync.ProtocolChangesTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents, Scopes}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Feed.UploadResult
  alias ReplicantServer.Sync.{Protocol, Upload}

  setup do
    {:ok, user} = Accounts.get_or_create_user("changes@example.com")
    %{user: user, own: Scopes.own(user.id)}
  end

  defp create(user, title) do
    Documents.create_document(user.id, %{id: Ecto.UUID.generate(), content: %{"title" => title}})
  end

  defp page(own, cursor, limit \\ 500) do
    Protocol.changes_since(own, "own", %{"cursor" => cursor, "limit" => limit})
  end

  test "an empty scope returns no changes and the feed head", %{own: own} do
    {:ok, other} = Accounts.get_or_create_user("changes-other@example.com")
    {:ok, theirs} = create(other, "theirs")
    assert {:ok, %{changes: [], has_more: false, next_cursor: head}} = page(own, 0)
    assert head >= theirs.seq
  end

  test "upserts carry the current document; deleted documents appear only as deletes", %{
    user: user,
    own: own
  } do
    {:ok, a} = create(user, "a")
    {:ok, b} = create(user, "b")
    {:ok, _} = Documents.delete_document(user.id, b.id)

    assert {:ok, %{changes: [upsert, delete], has_more: false}} = page(own, 0)
    assert %{scope: "own", kind: "upsert", doc_id: a_id, doc: %{title: "a", seq: a_seq}} = upsert
    assert %{kind: "delete", doc_id: b_id, doc: nil} = delete
    assert {a_id, a_seq, b_id} == {a.id, a.seq, b.id}
  end

  test "limit pages the feed", %{user: user, own: own} do
    for t <- ~w(1 2 3), do: create(user, t)
    assert {:ok, %{changes: [_, second], has_more: true, next_cursor: cursor}} = page(own, 0, 2)
    assert cursor == second.seq
    assert {:ok, %{changes: [_], has_more: false}} = page(own, cursor, 2)
  end

  test "a huge limit and a missing limit both cap at 500", %{own: own} do
    rows =
      for _ <- 1..501 do
        [[seq]] = Repo.query!("SELECT nextval('change_seq')").rows

        {:ok, doc_id} = Ecto.UUID.dump(Ecto.UUID.generate())

        %{
          seq: seq,
          scope: own,
          prev_seq: 0,
          doc_id: doc_id,
          kind: "delete",
          inserted_at: DateTime.utc_now()
        }
      end

    Repo.insert_all("change_events", rows)

    assert {:ok, %{changes: default_page, has_more: true}} =
             Protocol.changes_since(own, "own", %{"cursor" => 0})

    assert length(default_page) == 500

    assert {:ok, %{changes: huge_limit_page, has_more: true}} = page(own, 0, 10_000)
    assert length(huge_limit_page) == 500
  end

  test "an invalid limit falls back to the default instead of crashing", %{own: own} do
    assert {:ok, %{changes: []}} = page(own, 0, 0)
    assert {:ok, %{changes: []}} = page(own, 0, -5)

    assert {:ok, %{changes: []}} =
             Protocol.changes_since(own, "own", %{"cursor" => 0, "limit" => "abc"})
  end

  test "a cursor older than the trim watermark gets cursor_too_old with the scope", %{own: own} do
    Repo.query!("UPDATE change_feed_state SET trim_watermark = 50 WHERE id = 1")
    assert {:error, %{code: "cursor_too_old", is_fatal: false, scope: "own"}} = page(own, 10)
  end

  test "a missing or negative cursor is validation", %{own: own} do
    assert {:error, %{code: "validation"}} = Protocol.changes_since(own, "own", %{})
    assert {:error, %{code: "validation"}} = page(own, -1)
  end

  test "a cursor beyond bigint range is validation", %{own: own} do
    assert {:error, %{code: "validation", scope: "own"}} = page(own, 9_223_372_036_854_775_808)
  end

  test "a cursor past the feed head is cursor_too_old", %{own: own} do
    assert {:error, %{code: "cursor_too_old", scope: "own"}} = page(own, 9_000_000_000_000)
  end

  defp upload_create(user, content) do
    upload_id = Ecto.UUID.generate()

    {:ok, reply} =
      Upload.run(user.id, nil, %{
        "upload_id" => upload_id,
        "doc_id" => Ecto.UUID.generate(),
        "kind" => "create",
        "payload" => content
      })

    {upload_id, reply}
  end

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  test "an upload's upsert carries the document as of that upload, not a later edit", %{
    user: user,
    own: own
  } do
    {upload_id, uploaded} = upload_create(user, %{"title" => "uploaded"})
    doc = Repo.get!(Document, uploaded.doc_id)
    {:ok, edited} = Documents.replace_content(doc, %{"title" => "web edit"})

    assert {:ok, %{changes: [first, second]}} = page(own, 0)

    assert %{upload_id: ^upload_id, seq: upload_seq} = first
    assert upload_seq == uploaded.seq
    assert json(first.doc) == json(uploaded)
    assert %{"content" => %{"title" => "uploaded"}, "seq" => ^upload_seq} = json(first.doc)
    assert json(first.doc)["hash"] == Documents.compute_hash(%{"title" => "uploaded"})

    assert %{upload_id: nil, seq: edit_seq, doc: %{content: %{"title" => "web edit"}}} = second
    assert edit_seq == edited.seq
  end

  test "an upload's upsert falls back to the current document when no reply is stored", %{
    user: user,
    own: own
  } do
    {upload_id, uploaded} = upload_create(user, %{"title" => "uploaded"})
    doc = Repo.get!(Document, uploaded.doc_id)
    {:ok, _edited} = Documents.replace_content(doc, %{"title" => "web edit"})
    Repo.delete_all(from u in UploadResult, where: u.upload_id == ^upload_id)

    assert {:ok, %{changes: [first, _second]}} = page(own, 0)
    assert %{upload_id: ^upload_id, doc: %{content: %{"title" => "web edit"}}} = first
  end
end
