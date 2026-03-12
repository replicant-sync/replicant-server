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

  @allowed_sort_fields ~w(title size_bytes sync_revision updated_at created_at)a

  @doc """
  Lists all non-deleted documents for a user with optional sorting, search, and filters.
  """
  def list_user_documents(user_id, opts \\ []) do
    sort_by = validate_field(opts[:sort_by], :updated_at)
    sort_order = validate_order(opts[:sort_order], :desc)
    search = opts[:search]
    filters = opts[:filters] || []

    from(d in Document, where: d.user_id == ^user_id and is_nil(d.deleted_at))
    |> maybe_search(search)
    |> apply_json_filters(filters)
    |> order_by([d], [{^sort_order, ^sort_by}])
    |> Repo.all()
  end

  @doc """
  Creates a document with event logging in a transaction.

  Returns `{:ok, document}` or `{:error, reason}` or `{:error, :conflict, existing_doc}`.
  """
  def create_document(user_id, attrs) do
    document_id = attrs[:id] || attrs["id"]
    content = attrs[:content] || attrs["content"]
    content_hash = compute_hash(content)

    case find_by_content_hash(user_id, content_hash) do
      %Document{} = existing ->
        {:ok, existing}

      nil ->
        Multi.new()
        |> Multi.insert(:document, fn _ ->
          %Document{}
          |> Document.create_changeset(%{
            id: document_id,
            user_id: user_id,
            content: content,
            content_hash: content_hash,
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
  end

  @doc """
  Updates a document with content hash validation and event logging.

  The patch should be a JSON Patch (RFC 6902) operation list.
  Validates that the client's content_hash matches the current document's hash
  to ensure the client was working with the correct base content.
  Returns `{:ok, document}` or `{:error, :hash_mismatch, current_doc}` or `{:error, reason}`.
  """
  def update_document(user_id, document_id, patch, content_hash) do
    case get_user_document(user_id, document_id) do
      nil ->
        {:error, :not_found}

      document ->
        current_hash = document.content_hash
        if content_hash != nil and current_hash != content_hash do
          {:error, :hash_mismatch, document}
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

  # --- Document copying / sharing ---

  @doc """
  Copies a single document to another user.

  Creates a new document under `target_user_id` with the same content.
  Skips if an identical document (by content hash) already exists for the target user.

  Returns `{:ok, document}` or `{:error, reason}`.
  """
  def copy_document_to_user(document_id, source_user_id, target_user_id) do
    case get_user_document(source_user_id, document_id) do
      nil -> {:error, :not_found}
      doc -> create_document(target_user_id, %{id: Ecto.UUID.generate(), content: doc.content})
    end
  end

  @doc """
  Copies all documents from one user to another.

  Skips documents that already exist for the target user (by content hash).
  Returns `{:ok, %{copied: count, skipped: count}}`.
  """
  def copy_all_documents(source_user_id, target_user_id) do
    docs = list_user_documents(source_user_id)

    results =
      Enum.map(docs, fn doc ->
        new_id = Ecto.UUID.generate()
        {new_id, create_document(target_user_id, %{id: new_id, content: doc.content})}
      end)

    copied = Enum.count(results, fn
      {new_id, {:ok, doc}} -> doc.id == new_id
      _ -> false
    end)

    skipped = length(docs) - copied

    {:ok, %{copied: copied, skipped: skipped}}
  end

  @doc """
  Copies all documents from one user email to another.

  Convenience wrapper that resolves emails to user IDs.
  Returns `{:ok, %{copied: count, skipped: count}}` or `{:error, reason}`.

  ## Example

      iex> Documents.copy_all_documents_by_email("source@example.com", "target@example.com")
      {:ok, %{copied: 42, skipped: 0}}
  """
  def copy_all_documents_by_email(source_email, target_email) do
    source_id = ReplicantServer.Auth.deterministic_user_id(source_email)
    target_id = ReplicantServer.Auth.deterministic_user_id(target_email)

    # Ensure target user exists
    ReplicantServer.Accounts.get_or_create_user(target_email)

    copy_all_documents(source_id, target_id)
  end

  # --- Public documents (user_id IS NULL) ---

  @doc """
  Lists all non-deleted public documents (user_id is nil) with optional sorting, search, and filters.
  """
  def list_public_documents(opts \\ []) do
    sort_by = validate_field(opts[:sort_by], :updated_at)
    sort_order = validate_order(opts[:sort_order], :desc)
    search = opts[:search]
    filters = opts[:filters] || []

    from(d in Document, where: is_nil(d.user_id) and is_nil(d.deleted_at))
    |> maybe_search(search)
    |> apply_json_filters(filters)
    |> order_by([d], [{^sort_order, ^sort_by}])
    |> Repo.all()
  end

  @doc """
  Gets a single public document by ID.
  """
  def get_public_document(id) do
    Repo.one(
      from d in Document,
        where: d.id == ^id and is_nil(d.user_id) and is_nil(d.deleted_at)
    )
  end

  @doc """
  Creates a public document (no user_id).
  """
  def create_public_document(attrs) do
    document_id = attrs[:id] || attrs["id"] || Ecto.UUID.generate()
    content = attrs[:content] || attrs["content"]
    content_hash = compute_hash(content)

    case find_public_by_content_hash(content_hash) do
      %Document{} = existing ->
        {:ok, existing}

      nil ->
        %Document{}
        |> Document.create_changeset(%{
          id: document_id,
          user_id: nil,
          content: content,
          content_hash: content_hash,
          title: extract_title(content),
          size_bytes: compute_size(content)
        })
        |> Repo.insert()
        |> case do
          {:ok, doc} ->
            broadcast("documents:public", {:document_created, doc})
            {:ok, doc}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Replaces a document's content entirely. Computes JSON Patch internally
  so event history is preserved. Works for both user and public documents.
  """
  def replace_content(document, new_content) when is_map(new_content) do
    patch = Jsonpatch.diff(document.content, new_content)

    if patch == [] do
      {:ok, document}
    else
      case apply_update(document, patch) do
        {:ok, updated} ->
          broadcast("documents:#{document.id}", {:document_updated, updated})

          if document.user_id do
            broadcast("documents:user:#{document.user_id}", {:document_updated, updated})
          else
            broadcast("documents:public", {:document_updated, updated})
          end

          {:ok, updated}

        error ->
          error
      end
    end
  end

  @doc """
  Soft-deletes a public document.
  """
  def delete_public_document(document_id) do
    case get_public_document(document_id) do
      nil ->
        {:error, :not_found}

      document ->
        document
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update()
        |> case do
          {:ok, doc} ->
            broadcast("documents:public", {:document_deleted, doc})
            {:ok, doc}

          error ->
            error
        end
    end
  end

  defp find_by_content_hash(user_id, content_hash) when is_binary(content_hash) do
    Repo.one(
      from d in Document,
        where: d.user_id == ^user_id and d.content_hash == ^content_hash and is_nil(d.deleted_at),
        limit: 1
    )
  end

  defp find_by_content_hash(_user_id, _content_hash), do: nil

  defp find_public_by_content_hash(content_hash) when is_binary(content_hash) do
    Repo.one(
      from d in Document,
        where: is_nil(d.user_id) and d.content_hash == ^content_hash and is_nil(d.deleted_at),
        limit: 1
    )
  end

  defp find_public_by_content_hash(_content_hash), do: nil

  defp validate_field(nil, default), do: default
  defp validate_field(field, default) when is_binary(field) do
    case String.to_existing_atom(field) do
      f when f in @allowed_sort_fields -> f
      _ -> default
    end
  rescue
    ArgumentError -> default
  end
  defp validate_field(field, default) when is_atom(field) do
    if field in @allowed_sort_fields, do: field, else: default
  end

  defp validate_order(:asc, _default), do: :asc
  defp validate_order("asc", _default), do: :asc
  defp validate_order(:desc, _default), do: :desc
  defp validate_order("desc", _default), do: :desc
  defp validate_order(_, default), do: default

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query
  defp maybe_search(query, term) do
    sanitized = "%#{sanitize_like(term)}%"
    from d in query,
      where: ilike(d.title, ^sanitized) or ilike(type(d.content, :string), ^sanitized)
  end

  defp apply_json_filters(query, []), do: query
  defp apply_json_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, q ->
      if key != "" and value != "" do
        sanitized = "%#{sanitize_like(value)}%"
        from d in q,
          where: ilike(fragment("?->>?", d.content, ^key), ^sanitized)
      else
        q
      end
    end)
  end

  defp sanitize_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(ReplicantServer.PubSub, topic, message)
  end

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
