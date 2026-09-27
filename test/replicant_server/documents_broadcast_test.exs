defmodule ReplicantServer.DocumentsBroadcastTest do
  @moduledoc "Document writes reach sync clients via the change feed and host UIs via `documents:*` topics."
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents, Feed, Scopes}

  setup do
    {:ok, user} = Accounts.get_or_create_user("broadcast-test@example.com")
    Phoenix.PubSub.subscribe(ReplicantServer.PubSub, Feed.topic(Scopes.own(user.id)))
    %{user: user}
  end

  defp create(user, content) do
    Documents.create_document(user.id, %{"id" => Ecto.UUID.generate(), "content" => content})
  end

  test "create broadcasts an upsert carrying the new document", %{user: user} do
    {:ok, doc} = create(user, %{"title" => "Created via web"})

    assert_receive {:feed_change, %{kind: "upsert", seq: seq, doc_id: id},
                    %{content: %{"title" => "Created via web"}}}

    assert {id, seq} == {doc.id, doc.seq}
  end

  test "replace_content broadcasts an upsert; unchanged content broadcasts nothing", %{user: user} do
    {:ok, doc} = create(user, %{"title" => "Original"})
    assert_receive {:feed_change, _, _}
    {:ok, updated} = Documents.replace_content(doc, %{"title" => "Updated"})

    assert_receive {:feed_change, %{kind: "upsert", seq: seq},
                    %{content: %{"title" => "Updated"}}}

    assert seq == updated.seq
    {:ok, _} = Documents.replace_content(updated, %{"title" => "Updated"})
    refute_receive {:feed_change, _, _}
  end

  test "delete broadcasts a delete", %{user: user} do
    {:ok, doc} = create(user, %{"title" => "Doomed"})
    assert_receive {:feed_change, _, _}
    {:ok, deleted} = Documents.delete_document(user.id, doc.id)
    assert_receive {:feed_change, %{kind: "delete", seq: seq}, _}
    assert seq == deleted.seq
  end

  test "host UIs still get documents:user messages", %{user: user} do
    Phoenix.PubSub.subscribe(ReplicantServer.PubSub, "documents:user:#{user.id}")
    {:ok, doc} = create(user, %{"title" => "Web"})
    assert_receive {:document_created, %{id: id}}
    assert id == doc.id
  end
end
