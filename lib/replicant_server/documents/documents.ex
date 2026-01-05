defmodule ReplicantServer.Documents do
  @moduledoc """
  The Documents context for document CRUD with event logging.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias ReplicantServer.Repo
  alias ReplicantServer.Documents.{Document, ChangeEvent}

  @doc """
  Gets a document by ID.
  """
  def get_document(id) do
    Repo.get(Document, id)
  end

  @doc """
  Gets a document by ID, only if owned by user and not deleted.
  """
  def get_user_document(user_id, document_id) do
    Repo.one(
      from d in Document,
        where: d.id == ^document_id and d.user_id == ^user_id and is_nil(d.deleted_at)
    )
  end

  @doc """
  Lists all non-deleted documents for a user.
  """
  def list_user_documents(user_id) do
    Repo.all(
      from d in Document,
        where: d.user_id == ^user_id and is_nil(d.deleted_at),
        order_by: [desc: d.updated_at]
    )
  end

  @doc """
  Creates a document with event logging in a transaction.

  Returns `{:ok, document}` or `{:error, reason}` or `{:error, :conflict, existing_doc}`.
  """
  def create_document(user_id, attrs) do
    document_id = attrs[:id] || attrs["id"]
    content = attrs[:content] || attrs["content"]

    Multi.new()
    |> Multi.insert(:document, fn _ ->
      %Document{}
      |> Document.create_changeset(%{
        id: document_id,
        user_id: user_id,
        content: content,
        content_hash: compute_hash(content),
        title: extract_title(content),
        size_bytes: compute_size(content)
      })
    end)
    |> Multi.insert(:event, fn %{document: doc} ->
      %ChangeEvent{}
      |> ChangeEvent.changeset(%{
        document_id: doc.id,
        user_id: user_id,
        event_type: "create",
        forward_patch: content
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{document: document}} ->
        {:ok, document}

      {:error, :document, %Ecto.Changeset{errors: errors}, _} ->
        if Keyword.has_key?(errors, :id) do
          # Conflict - document already exists
          case get_document(document_id) do
            nil -> {:error, :insert_failed}
            existing -> {:error, :conflict, existing}
          end
        else
          {:error, :insert_failed}
        end

      {:error, _, _, _} ->
        {:error, :insert_failed}
    end
  end

  @doc """
  Updates a document with optimistic locking and event logging.

  The patch should be a JSON Patch (RFC 6902) operation list.
  Returns `{:ok, document}` or `{:error, :version_mismatch, current_doc}` or `{:error, reason}`.
  """
  def update_document(user_id, document_id, patch, expected_revision) do
    case get_user_document(user_id, document_id) do
      nil ->
        {:error, :not_found}

      document ->
        if document.sync_revision != expected_revision do
          {:error, :version_mismatch, document}
        else
          apply_update(document, patch)
        end
    end
  end

  @doc """
  Applies a patch to a document, computing forward/reverse patches.
  """
  def apply_update(document, patch) do
    normalized_patch = normalize_patch(patch)

    case Jsonpatch.apply_patch(normalized_patch, document.content) do
      {:ok, new_content} ->
        reverse_patch = Jsonpatch.diff(new_content, document.content)

        Multi.new()
        |> Multi.update(:document, fn _ ->
          document
          |> Document.changeset(%{
            content: new_content,
            content_hash: compute_hash(new_content),
            title: extract_title(new_content),
            size_bytes: compute_size(new_content),
            sync_revision: document.sync_revision + 1
          })
        end)
        |> Multi.insert(:event, fn %{document: doc} ->
          %ChangeEvent{}
          |> ChangeEvent.changeset(%{
            document_id: doc.id,
            user_id: doc.user_id,
            event_type: "update",
            forward_patch: patch,
            reverse_patch: reverse_patch
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{document: updated_doc}} ->
            {:ok, updated_doc}

          {:error, _, _, _} ->
            {:error, :update_failed}
        end

      {:error, _} ->
        {:error, :invalid_patch}
    end
  end

  @doc """
  Soft deletes a document with event logging.
  """
  def delete_document(user_id, document_id) do
    case get_user_document(user_id, document_id) do
      nil ->
        {:error, :not_found}

      document ->
        Multi.new()
        |> Multi.update(:document, fn _ ->
          document
          |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        end)
        |> Multi.insert(:event, fn _ ->
          %ChangeEvent{}
          |> ChangeEvent.changeset(%{
            document_id: document.id,
            user_id: user_id,
            event_type: "delete",
            reverse_patch: document.content
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{document: deleted_doc}} -> {:ok, deleted_doc}
          {:error, _, _, _} -> {:error, :delete_failed}
        end
    end
  end

  @doc """
  Gets change events since a given sequence number.
  """
  def get_changes_since(user_id, last_sequence, limit \\ 100) do
    Repo.all(
      from e in ChangeEvent,
        where: e.user_id == ^user_id and e.sequence > ^last_sequence,
        order_by: [asc: e.sequence],
        limit: ^limit
    )
  end

  @doc """
  Gets the latest sequence number for a user.
  """
  def get_latest_sequence(user_id) do
    Repo.one(
      from e in ChangeEvent,
        where: e.user_id == ^user_id,
        select: max(e.sequence)
    ) || 0
  end

  @doc """
  Computes SHA256 hash of content for verification.
  """
  def compute_hash(content) when is_map(content) do
    content
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def compute_hash(_), do: nil

  @doc """
  Verifies content matches expected hash.
  """
  def verify_hash(content, expected_hash) do
    compute_hash(content) == expected_hash
  end

  defp extract_title(content) when is_map(content) do
    content["title"] || content[:title]
  end

  defp extract_title(_), do: nil

  defp compute_size(content) when is_map(content) do
    content |> Jason.encode!() |> byte_size()
  end

  defp compute_size(_), do: 0

  defp normalize_patch(patch) when is_list(patch) do
    Enum.map(patch, &normalize_operation/1)
  end

  defp normalize_operation(op) when is_map(op) do
    op
    |> Map.new(fn
      {"op", v} -> {:op, v}
      {"path", v} -> {:path, v}
      {"value", v} -> {:value, v}
      {"from", v} -> {:from, v}
      {k, v} when is_atom(k) -> {k, v}
      {k, v} -> {String.to_existing_atom(k), v}
    end)
  end
end
