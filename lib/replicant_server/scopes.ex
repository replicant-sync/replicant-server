defmodule ReplicantServer.Scopes do
  @moduledoc """
  Replication scopes. Server keys are `own:<user_id>` and `collection:<name>`;
  clients see `own` and `collection:<name>`.
  """

  import Ecto.Query

  alias ReplicantServer.Repo
  alias ReplicantServer.Collections.{Collection, CollectionMember}
  alias ReplicantServer.Documents.Document

  def own(user_id), do: "own:" <> user_id
  def collection(name), do: "collection:" <> name

  def resolve("own", user_id), do: {:ok, own(user_id)}

  def resolve("collection:" <> name, user_id) do
    case Repo.get_by(Collection, name: name) do
      %Collection{access: "public"} -> {:ok, collection(name)}
      %Collection{owner_id: ^user_id} when not is_nil(user_id) -> {:ok, collection(name)}
      _ -> {:error, :subscription_forbidden}
    end
  end

  def resolve(_scope, _user_id), do: {:error, :subscription_forbidden}

  def to_wire("own:" <> _user_id), do: "own"
  def to_wire(scope), do: scope

  def for_document(%Document{read_only: true, id: id}) do
    Repo.all(
      from m in CollectionMember,
        join: c in Collection,
        on: c.id == m.collection_id,
        where: m.document_id == ^id,
        select: c.name
    )
    |> Enum.map(&collection/1)
  end

  def for_document(%Document{user_id: nil}), do: []
  def for_document(%Document{user_id: user_id}), do: [own(user_id)]

  def documents_query("own:" <> user_id) do
    from d in Document,
      where: d.user_id == ^user_id and not d.read_only and is_nil(d.deleted_at)
  end

  def documents_query("collection:" <> name) do
    from d in Document,
      join: m in CollectionMember,
      on: m.document_id == d.id,
      join: c in Collection,
      on: c.id == m.collection_id,
      where: c.name == ^name and is_nil(d.deleted_at)
  end
end
