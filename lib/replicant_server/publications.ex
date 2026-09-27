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
end
