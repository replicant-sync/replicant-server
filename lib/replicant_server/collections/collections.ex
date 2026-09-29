defmodule ReplicantServer.Collections do
  @moduledoc "Collections of publications. Adding emits an upsert and removing a leave in the collection's scope."

  alias ReplicantServer.{Documents, Feed, Repo, Scopes}
  alias ReplicantServer.Collections.{Collection, CollectionMember}
  alias ReplicantServer.Documents.Document

  @curated "curated"

  def curated, do: @curated

  def get_by_name(name), do: Repo.get_by(Collection, name: name)

  def add(name, publication_id) do
    Documents.run_write(fn ->
      case Documents.lock_document(publication_id) do
        %Document{read_only: true, deleted_at: nil} = pub -> do_add(name, pub)
        %Document{read_only: true} -> {:error, :not_found}
        %Document{} -> {:error, :not_publication}
        nil -> {:error, :not_found}
      end
    end)
  end

  @doc false
  def do_add(name, %Document{} = pub) do
    case get_by_name(name) do
      nil ->
        {:error, :not_found}

      collection ->
        if Repo.get_by(CollectionMember, collection_id: collection.id, document_id: pub.id) do
          {:ok, pub, []}
        else
          {seq, events} =
            Feed.record([Scopes.collection(name)], %{
              doc_id: pub.id,
              kind: "upsert",
              hash: pub.content_hash
            })

          Repo.insert!(%CollectionMember{
            collection_id: collection.id,
            document_id: pub.id,
            added_seq: seq
          })

          {:ok, updated} = pub |> Ecto.Changeset.change(seq: seq) |> Repo.update()
          {:ok, updated, events}
        end
    end
  end

  def remove(name, publication_id) do
    Documents.run_write(fn ->
      with %Collection{} = collection <- get_by_name(name) || {:error, :not_found},
           %Document{} = pub <- Documents.lock_document(publication_id) || {:error, :not_found},
           %CollectionMember{} = member <-
             Repo.get_by(CollectionMember, collection_id: collection.id, document_id: pub.id) ||
               {:error, :not_member} do
        Repo.delete!(member)
        {seq, events} = Feed.record([Scopes.collection(name)], %{doc_id: pub.id, kind: "leave"})
        {:ok, updated} = pub |> Ecto.Changeset.change(seq: seq) |> Repo.update()
        {:ok, updated, events}
      end
    end)
  end
end
