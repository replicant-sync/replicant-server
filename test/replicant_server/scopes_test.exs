defmodule ReplicantServer.ScopesTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Scopes}
  alias ReplicantServer.Collections.{Collection, CollectionMember}
  alias ReplicantServer.Documents.Document

  setup do
    {:ok, user} = Accounts.get_or_create_user("scopes@example.com")
    %{user: user, curated: Repo.get_by!(Collection, name: "curated")}
  end

  defp insert_doc(attrs) do
    Repo.insert!(
      struct(%Document{id: Ecto.UUID.generate(), content: %{}, content_hash: "h"}, attrs)
    )
  end

  defp add_member(collection, doc) do
    Repo.insert!(%CollectionMember{
      collection_id: collection.id,
      document_id: doc.id,
      added_seq: 1
    })
  end

  test "resolve/2 maps own to the caller's feed and allows public collections", %{user: user} do
    assert Scopes.resolve("own", user.id) == {:ok, "own:" <> user.id}
    assert Scopes.resolve("collection:curated", user.id) == {:ok, "collection:curated"}
  end

  test "resolve/2 refuses unknown scopes and other users' private collections", %{user: user} do
    {:ok, other} = Accounts.get_or_create_user("scopes-other@example.com")
    Repo.insert!(%Collection{name: "private-pack", owner_id: other.id, access: "private"})

    assert Scopes.resolve("collection:private-pack", user.id) == {:error, :subscription_forbidden}
    assert Scopes.resolve("collection:private-pack", other.id) == {:ok, "collection:private-pack"}
    assert Scopes.resolve("collection:missing", user.id) == {:error, :subscription_forbidden}
    assert Scopes.resolve("everything", user.id) == {:error, :subscription_forbidden}
  end

  test "to_wire/1 hides the user id of own scopes" do
    assert Scopes.to_wire("own:abc") == "own"
    assert Scopes.to_wire("collection:curated") == "collection:curated"
  end

  test "for_document/1 routes sources to own and publications to their collections", %{
    user: user,
    curated: curated
  } do
    source = insert_doc(user_id: user.id)
    pub = insert_doc(read_only: true)
    add_member(curated, pub)

    assert Scopes.for_document(source) == ["own:" <> user.id]
    assert Scopes.for_document(pub) == ["collection:curated"]
    assert Scopes.for_document(insert_doc(read_only: true)) == []
    assert Scopes.for_document(insert_doc(%{})) == []
  end

  test "documents_query/1 selects live members of the scope", %{user: user, curated: curated} do
    mine = insert_doc(user_id: user.id)
    insert_doc(user_id: user.id, deleted_at: DateTime.utc_now())
    {:ok, other} = Accounts.get_or_create_user("scopes-q@example.com")
    insert_doc(user_id: other.id)
    pub = insert_doc(read_only: true)
    add_member(curated, pub)
    add_member(curated, insert_doc(read_only: true, deleted_at: DateTime.utc_now()))

    assert user.id |> Scopes.own() |> Scopes.documents_query() |> Repo.all() |> Enum.map(& &1.id) ==
             [mine.id]

    assert "collection:curated" |> Scopes.documents_query() |> Repo.all() |> Enum.map(& &1.id) ==
             [pub.id]
  end
end
