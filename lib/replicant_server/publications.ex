defmodule ReplicantServer.Publications do
  @moduledoc """
  Publications: read-only copies, changed only by these functions (never by
  `upload`). They reach clients only through collections.
  """

  alias ReplicantServer.{Collections, Documents}
  alias ReplicantServer.Documents.Document

  def create_curated(attrs) do
    attrs = Map.put_new_lazy(attrs, :id, &Ecto.UUID.generate/0)

    Documents.run_write(fn ->
      with {:ok, pub, _events} <- Documents.do_insert_publication(attrs) do
        Collections.do_add(Collections.curated(), pub)
      end
    end)
  end

  def unpublish_any(publication_id) do
    Documents.run_write(fn ->
      case Documents.lock_document(publication_id) do
        %Document{read_only: true, deleted_at: nil} = pub -> Documents.soft_delete(pub, %{})
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Publishes a read-only copy of a source document the caller owns. The
  publication starts outside every scope: it gets a seq (so `get_document`
  can be used on it right away) but no feed event, since it belongs to no
  scope yet. It joins a scope, and starts appearing in a feed, only via
  `Collections.add/2`.
  """
  def publish(user_id, source_doc_id) do
    Documents.run_write(fn ->
      case Documents.lock_document(source_doc_id) do
        %Document{user_id: ^user_id, read_only: false, deleted_at: nil} = source ->
          Documents.do_insert_publication(%{
            id: Ecto.UUID.generate(),
            content: source.content,
            author_id: user_id,
            author_name: source.author_name,
            source_doc_id: source.id,
            source_revision: source.seq
          })

        _ ->
          {:error, :not_found}
      end
    end)
  end

  @doc """
  Refreshes a publication with its source document's current content. Emits
  an upsert in every collection scope the publication already belongs to.
  """
  def publish_update(user_id, publication_id) do
    Documents.run_write(fn ->
      with {:ok, pub} <- lock_own_publication(user_id, publication_id),
           {:ok, source} <- live_source(pub, user_id) do
        Documents.write_content(pub, source.content, %{}, %{source_revision: source.seq})
      end
    end)
  end

  @doc """
  Soft-deletes a publication the caller authored. Emits a delete in every
  collection scope it belongs to and drops its collection memberships.
  """
  def unpublish(user_id, publication_id) do
    Documents.run_write(fn ->
      with {:ok, pub} <- lock_own_publication(user_id, publication_id) do
        Documents.soft_delete(pub, %{})
      end
    end)
  end

  defp lock_own_publication(user_id, publication_id) do
    case Documents.lock_document(publication_id) do
      %Document{read_only: true, deleted_at: nil, author_id: ^user_id} = pub -> {:ok, pub}
      %Document{read_only: true, deleted_at: nil} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  defp live_source(%Document{source_doc_id: nil}, _user_id), do: {:error, :not_found}

  defp live_source(%Document{source_doc_id: source_id}, user_id) do
    case Documents.get_document(source_id) do
      %Document{user_id: ^user_id, deleted_at: nil} = source -> {:ok, source}
      _ -> {:error, :not_found}
    end
  end
end
