defmodule ReplicantServer.Documents do
  @moduledoc """
  The Documents context for document CRUD with event logging.
  """

  import Ecto.Query
  alias ReplicantServer.{Feed, Repo, Scopes}
  alias ReplicantServer.Collections.CollectionMember
  alias ReplicantServer.Documents.Document

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
  Creates a source document owned by `user_id`. Content is never deduplicated.

  Returns `{:ok, document}`, `{:error, :conflict, existing}` when the id is
  taken (live or deleted), or `{:error, :insert_failed}`.
  """
  def create_document(user_id, attrs) do
    run_write(fn -> do_create(user_id, attrs, %{}) end)
    |> tap_ok(&broadcast("documents:user:#{user_id}", {:document_created, &1}))
  end

  @doc """
  Applies a JSON Patch to a source document the user owns, checked against
  `content_hash`. Returns `{:ok, document}`, `{:error, :hash_mismatch, current}`,
  or `{:error, :missing_hash | :not_found | :forbidden | :invalid_patch}`.
  """
  def update_document(user_id, document_id, patch, content_hash) do
    run_write(fn -> do_update(user_id, document_id, patch, content_hash, %{}) end)
  end

  @doc "Soft-deletes a source document the user owns; the row stays as a tombstone."
  def delete_document(user_id, document_id) do
    run_write(fn -> do_delete(user_id, document_id, %{}) end)
    |> tap_ok(fn doc ->
      broadcast("documents:#{doc.id}", {:document_deleted, doc})
      broadcast("documents:user:#{user_id}", {:document_deleted, doc})
    end)
  end

  @doc false
  def run_write(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, doc, events} -> {doc, events}
        error -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, {doc, events}} ->
        Feed.broadcast(events, doc)
        {:ok, doc}

      {:error, error} ->
        error
    end
  end

  @doc false
  def do_create(user_id, attrs, meta) do
    case Ecto.UUID.cast(attrs[:id] || attrs["id"]) do
      {:ok, id} ->
        scope = Scopes.own(user_id)
        Feed.lock_scopes([scope])

        case Repo.get(Document, id) do
          %Document{} = existing -> {:error, :conflict, existing}
          nil -> insert_source(user_id, id, attrs, scope, meta)
        end

      :error ->
        {:error, :insert_failed}
    end
  end

  defp insert_source(user_id, id, attrs, scope, meta) do
    content = attrs[:content] || attrs["content"]
    hash = compute_hash(content)
    {seq, events} = Feed.record([scope], event_attrs(id, "upsert", hash, meta))

    %Document{}
    |> Document.create_changeset(%{
      id: id,
      user_id: user_id,
      content: content,
      content_hash: hash,
      title: extract_title(content),
      author_name: attrs[:author_name] || attrs["author_name"] || target_author_name(user_id),
      provenance: attrs[:provenance] || attrs["provenance"] || %{},
      size_bytes: compute_size(content)
    })
    |> Ecto.Changeset.put_change(:seq, seq)
    |> Repo.insert()
    |> case do
      {:ok, doc} -> {:ok, doc, events}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  @doc false
  def do_update(_user_id, _document_id, _patch, nil, _meta), do: {:error, :missing_hash}

  def do_update(user_id, document_id, patch, base_hash, meta) do
    with {:ok, doc} <- lock_writable(user_id, document_id) do
      if doc.content_hash != base_hash do
        {:error, :hash_mismatch, doc}
      else
        with {:ok, content} <- apply_patch(patch, doc.content),
             do: write_content(doc, content, meta)
      end
    end
  end

  @doc false
  def do_delete(user_id, document_id, meta) do
    with {:ok, doc} <- lock_writable(user_id, document_id), do: soft_delete(doc, meta)
  end

  @doc false
  def lock_document(document_id) do
    case Ecto.UUID.cast(document_id) do
      {:ok, id} -> Repo.one(from d in Document, where: d.id == ^id, lock: "FOR UPDATE")
      :error -> nil
    end
  end

  @doc false
  def write_content(%Document{} = doc, content, meta, extra \\ %{}) do
    hash = compute_hash(content)

    {seq, events} =
      Feed.record(Scopes.for_document(doc), event_attrs(doc.id, "upsert", hash, meta))

    doc
    |> Document.changeset(
      Map.merge(
        %{
          content: content,
          content_hash: hash,
          title: extract_title(content),
          size_bytes: compute_size(content),
          sync_revision: doc.sync_revision + 1,
          seq: seq
        },
        extra
      )
    )
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated, events}
      {:error, _changeset} -> {:error, :update_failed}
    end
  end

  @doc false
  def soft_delete(%Document{} = doc, meta) do
    {seq, events} =
      Feed.record(Scopes.for_document(doc), event_attrs(doc.id, "delete", nil, meta))

    Repo.delete_all(from m in CollectionMember, where: m.document_id == ^doc.id)

    {:ok, deleted} =
      doc |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(), seq: seq) |> Repo.update()

    {:ok, deleted, events}
  end

  defp lock_writable(user_id, document_id) do
    case lock_document(document_id) do
      nil -> {:error, :not_found}
      %Document{deleted_at: %DateTime{}} -> {:error, :not_found}
      %Document{user_id: ^user_id, read_only: false} = doc -> {:ok, doc}
      %Document{} -> {:error, :forbidden}
    end
  end

  defp apply_patch(patch, content) when is_list(patch) do
    case Jsonpatch.apply_patch(normalize_patch(patch), content) do
      {:ok, new_content} -> {:ok, new_content}
      {:error, _} -> {:error, :invalid_patch}
    end
  rescue
    _ -> {:error, :invalid_patch}
  end

  defp apply_patch(_patch, _content), do: {:error, :invalid_patch}

  defp event_attrs(doc_id, kind, hash, meta) do
    %{
      doc_id: doc_id,
      kind: kind,
      hash: hash,
      client_id: meta[:client_id],
      upload_id: meta[:upload_id]
    }
  end

  defp tap_ok({:ok, doc} = result, fun) do
    fun.(doc)
    result
  end

  defp tap_ok(result, _fun), do: result

  @doc """
  Computes SHA256 hash of content for verification.

  Encodes with explicit key-sorted, compact JSON at every nesting level
  (`canonical_json/1`) rather than relying on `Jason.encode!/1`'s default map
  iteration order. Erlang's small maps (<=32 keys) happen to iterate in
  sorted term order already, so this is byte-identical to plain
  `Jason.encode!/1` only for small maps whose strings contain no control
  characters; existing stored `content_hash` values for such maps remain
  valid. Maps larger than 32 keys switch to an unordered HAMT
  representation, where the old approach could silently disagree with the
  Rust client's `BTreeMap`-backed encoder; explicit sorting fixes that case.
  """
  def compute_hash(content) when is_map(content) do
    content
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def compute_hash(_), do: nil

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), canonical_json(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {k, v} -> "#{encode_string(k)}:#{v}" end)
    |> then(&"{#{&1}}")
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map(&canonical_json/1)
    |> Enum.join(",")
    |> then(&"[#{&1}]")
  end

  defp canonical_json(value) when is_float(value), do: format_float(value)

  defp canonical_json(value) when is_binary(value), do: encode_string(value)

  defp canonical_json(value), do: Jason.encode!(value)

  # serde_json's escaping: short escapes for " \ \b \f \n \r \t, lowercase
  # \u00xx for other control characters, everything else verbatim.
  defp encode_string(string) do
    escaped =
      for <<c::utf8 <- string>>, into: "" do
        case c do
          ?" -> "\\\""
          ?\\ -> "\\\\"
          ?\b -> "\\b"
          ?\f -> "\\f"
          ?\n -> "\\n"
          ?\r -> "\\r"
          ?\t -> "\\t"
          c when c < 0x20 -> "\\u00" <> String.downcase(Base.encode16(<<c>>))
          c -> <<c::utf8>>
        end
      end

    "\"" <> escaped <> "\""
  end

  # Renders a float exactly as Rust's `ryu` crate does (what serde_json uses
  # for every f64), so document hashes agree across languages at magnitudes
  # where Jason's own formatter (`1.0e10`, `1.0e-7`, ...) disagrees with
  # serde_json (`10000000000.0`, `1e-7`, ...). Sources the shortest
  # round-trip digit string from `:erlang.float_to_binary/2`'s `:short` mode
  # (the same class of algorithm ryu implements) and re-renders it using
  # ryu's exact fixed/scientific notation switch
  # (see ryu's src/pretty/mod.rs `format64`).
  defp format_float(value) do
    erlang_short = value |> :erlang.float_to_binary([:short]) |> to_string()

    if value == 0.0 do
      if String.starts_with?(erlang_short, "-"), do: "-0.0", else: "0.0"
    else
      {sign, int_part, frac_part, exp} = parse_short_float(erlang_short)
      digits_all = int_part <> frac_part
      exponent = exp - String.length(frac_part)

      digits_no_leading = String.trim_leading(digits_all, "0")
      digits_no_leading = if digits_no_leading == "", do: "0", else: digits_no_leading

      {digits, k} = strip_trailing_zeros(digits_no_leading, exponent)
      length = String.length(digits)
      kk = length + k

      render_ryu(sign, digits, length, k, kk)
    end
  end

  defp parse_short_float(str) do
    {sign, rest} =
      case str do
        "-" <> r -> {"-", r}
        r -> {"", r}
      end

    [mantissa, exp_str] =
      case String.split(rest, "e", parts: 2) do
        [m] -> [m, "0"]
        [m, e] -> [m, e]
      end

    [int_part, frac_part] = String.split(mantissa, ".", parts: 2)
    {sign, int_part, frac_part, String.to_integer(exp_str)}
  end

  defp strip_trailing_zeros(digits, exponent) do
    trimmed = String.trim_trailing(digits, "0")
    trimmed = if trimmed == "", do: "0", else: trimmed
    {trimmed, exponent + (String.length(digits) - String.length(trimmed))}
  end

  # Mirrors ryu's `format64` branch-for-branch: fixed notation with trailing
  # ".0" for whole numbers, fixed with an interior decimal point, fixed with
  # leading zeros for small fractions, or scientific notation outside that
  # range.
  defp render_ryu(sign, digits, length, k, kk) do
    cond do
      k >= 0 and kk <= 16 ->
        sign <> digits <> String.duplicate("0", kk - length) <> ".0"

      kk > 0 and kk <= 16 ->
        {int_digits, frac_digits} = String.split_at(digits, kk)
        sign <> int_digits <> "." <> frac_digits

      kk > -5 and kk <= 0 ->
        sign <> "0." <> String.duplicate("0", -kk) <> digits

      length == 1 ->
        sign <> digits <> "e" <> Integer.to_string(kk - 1)

      true ->
        {first, rest} = String.split_at(digits, 1)
        sign <> first <> "." <> rest <> "e" <> Integer.to_string(kk - 1)
    end
  end

  @doc """
  Verifies content matches expected hash.
  """
  def verify_hash(content, expected_hash) do
    compute_hash(content) == expected_hash
  end

  defp extract_title(content) when is_map(content) do
    case content["title"] || content[:title] do
      title when is_binary(title) -> title
      _ -> nil
    end
  end

  defp extract_title(_), do: nil

  defp compute_size(content) when is_map(content) do
    content |> Jason.encode!() |> byte_size()
  end

  defp compute_size(_), do: 0

  # --- Document copying / sharing ---

  @doc "Copies a single document to another user as a new document."
  def copy_document_to_user(document_id, source_user_id, target_user_id) do
    case get_user_document(source_user_id, document_id) do
      nil -> {:error, :not_found}
      doc -> create_document(target_user_id, copy_attrs(doc, target_author_name(target_user_id)))
    end
  end

  defp target_author_name(target_user_id) do
    case ReplicantServer.Accounts.get_user(target_user_id) do
      nil -> nil
      user -> ReplicantServer.Accounts.display_name(user)
    end
  end

  defp copy_attrs(source_doc, author_name) do
    %{
      id: Ecto.UUID.generate(),
      content: source_doc.content,
      author_name: author_name,
      provenance: %{
        "copied_from" => source_doc.id,
        "source_author_id" => source_doc.user_id,
        "source_author_name" => source_doc.author_name
      }
    }
  end

  @doc """
  Copies all documents from one user to another. Returns `{:ok, %{copied: count, skipped: count}}`;
  a copy is skipped only if its insert fails.
  """
  def copy_all_documents(source_user_id, target_user_id) do
    docs = list_user_documents(source_user_id)
    author_name = target_author_name(target_user_id)

    results =
      Enum.map(docs, fn doc ->
        attrs = copy_attrs(doc, author_name)
        {attrs.id, create_document(target_user_id, attrs)}
      end)

    copied =
      Enum.count(results, fn
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
    with %ReplicantServer.Accounts.User{} = source <-
           ReplicantServer.Accounts.get_user_by_email(source_email),
         {:ok, target} <- ReplicantServer.Accounts.get_or_create_user(target_email) do
      copy_all_documents(source.id, target.id)
    else
      nil -> {:error, :source_not_found}
      error -> error
    end
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

    from(d in Document, where: d.visibility == "public" and is_nil(d.deleted_at))
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
        where: d.id == ^id and d.visibility == "public" and is_nil(d.deleted_at)
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
          visibility: "public",
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
  Replaces a document's content (source or publication) and emits an upsert to
  every scope it belongs to. Unchanged content is a no-op.
  """
  def replace_content(%Document{} = document, new_content) when is_map(new_content) do
    if json_diff(document.content, new_content) == [] do
      {:ok, document}
    else
      run_write(fn ->
        case lock_document(document.id) do
          %Document{deleted_at: nil} = locked -> write_content(locked, new_content, %{})
          _ -> {:error, :not_found}
        end
      end)
      |> tap_ok(fn updated ->
        broadcast("documents:#{updated.id}", {:document_updated, updated})

        if updated.user_id do
          broadcast("documents:user:#{updated.user_id}", {:document_updated, updated})
        else
          broadcast("documents:public", {:document_updated, updated})
        end
      end)
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

  defp find_public_by_content_hash(content_hash) when is_binary(content_hash) do
    Repo.one(
      from d in Document,
        where:
          d.visibility == "public" and d.content_hash == ^content_hash and is_nil(d.deleted_at),
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

  @patch_keys %{"op" => :op, "path" => :path, "value" => :value, "from" => :from}

  defp normalize_operation(op) when is_map(op) do
    Map.new(op, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} -> {Map.get(@patch_keys, k, k), v}
    end)
  end

  # Compute a JSON Patch (RFC 6902) diff as plain maps.
  # Jsonpatch.diff returns Operation structs that lack an "op" field and don't
  # implement Jason.Encoder, so we convert immediately.
  defp json_diff(source, target) do
    Jsonpatch.diff(source, target)
    |> Enum.map(&op_to_map/1)
  end

  defp op_to_map(%Jsonpatch.Operation.Add{path: path, value: value}),
    do: %{op: "add", path: path, value: value}

  defp op_to_map(%Jsonpatch.Operation.Remove{path: path}),
    do: %{op: "remove", path: path}

  defp op_to_map(%Jsonpatch.Operation.Replace{path: path, value: value}),
    do: %{op: "replace", path: path, value: value}

  defp op_to_map(%Jsonpatch.Operation.Move{path: path, from: from}),
    do: %{op: "move", path: path, from: from}

  defp op_to_map(%Jsonpatch.Operation.Copy{path: path, from: from}),
    do: %{op: "copy", path: path, from: from}

  defp op_to_map(%Jsonpatch.Operation.Test{path: path, value: value}),
    do: %{op: "test", path: path, value: value}

  defp op_to_map(op) when is_map(op), do: op
end
