defmodule ReplicantServer.Sync.Protocol do
  @moduledoc "Request handlers for the v2 channel. Each returns a Phoenix reply: `{:ok, map}` or `{:error, map}`."

  import Ecto.Query

  alias ReplicantServer.{Feed, Repo, Scopes}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Feed.UploadResult
  alias ReplicantServer.Sync.Envelope

  @max_page 500
  @snapshot_page 200
  @max_bigint 9_223_372_036_854_775_807

  def changes_since(scope_key, wire_scope, %{"cursor" => cursor} = params)
      when is_integer(cursor) and cursor >= 0 and cursor <= @max_bigint do
    # One transaction keeps the scope lock taken by Feed.head/1 while documents load, so no
    # write to this scope can commit between the feed read and the document read.
    Repo.transaction(fn ->
      case Feed.changes_since(scope_key, cursor, page_limit(params["limit"])) do
        {:ok, page} -> changes_page(page, wire_scope)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, reply} ->
        {:ok, reply}

      {:error, :cursor_too_old} ->
        {:error, Envelope.error("cursor_too_old", %{scope: wire_scope})}
    end
  end

  def changes_since(_scope_key, wire_scope, _params) do
    {:error, Envelope.error("validation", %{scope: wire_scope})}
  end

  defp changes_page(page, wire_scope) do
    docs = load_docs(for e <- page.events, e.kind == "upsert", do: e.doc_id)
    kept = for e <- page.events, e.kind != "upsert" or live?(docs[e.doc_id]), do: e
    replies = load_upload_replies(for e <- kept, superseded_upload?(e, docs), do: e)

    changes =
      for event <- kept, do: Envelope.change(event, doc_as_of(event, docs, replies), wire_scope)

    %{changes: changes, next_cursor: page.next_cursor, has_more: page.has_more}
  end

  defp page_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_page)
  defp page_limit(_limit), do: @max_page

  def snapshot(scope_key, wire_scope, params, page_size \\ @snapshot_page) do
    case decode_token(params["page_token"]) do
      {:ok, nil} ->
        {:ok, snapshot_seq} = Repo.transaction(fn -> Feed.head(scope_key) end)
        {:ok, snapshot_page(scope_key, snapshot_seq, nil, page_size)}

      {:ok, {snapshot_seq, after_id}} ->
        {:ok, snapshot_page(scope_key, snapshot_seq, after_id, page_size)}

      :error ->
        {:error, Envelope.error("validation", %{scope: wire_scope})}
    end
  end

  defp snapshot_page(scope_key, snapshot_seq, after_id, page_size) do
    query = Scopes.documents_query(scope_key)
    query = if after_id, do: from(d in query, where: d.id > ^after_id), else: query
    docs = Repo.all(from d in query, order_by: d.id, limit: ^page_size)
    next = if length(docs) == page_size, do: "#{snapshot_seq}:#{List.last(docs).id}"
    %{docs: Enum.map(docs, &Envelope.doc/1), snapshot_seq: snapshot_seq, next_page_token: next}
  end

  defp decode_token(nil), do: {:ok, nil}

  defp decode_token(token) when is_binary(token) do
    with [seq, id] <- String.split(token, ":", parts: 2),
         {seq, ""} <- Integer.parse(seq),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {seq, id}}
    else
      _ -> :error
    end
  end

  defp decode_token(_token), do: :error

  def get_document(user_id, %{"doc_id" => doc_id}) when is_binary(doc_id) do
    with {:ok, id} <- Ecto.UUID.cast(doc_id),
         %Document{} = doc <- Repo.get(Document, id),
         true <- readable?(doc, user_id) do
      get_document_reply(doc)
    else
      _ -> {:error, Envelope.error("not_found", %{doc_id: doc_id})}
    end
  end

  def get_document(_user_id, params) do
    {:error, Envelope.error("validation", %{doc_id: safe_doc_id(params)})}
  end

  defp get_document_reply(%Document{deleted_at: nil} = doc), do: {:ok, Envelope.doc(doc)}

  defp get_document_reply(%Document{deleted_at: %DateTime{}} = doc) do
    {:error, Envelope.error("deleted", %{doc_id: doc.id, current_seq: doc.seq})}
  end

  defp readable?(%Document{user_id: user_id}, user_id), do: true
  defp readable?(%Document{read_only: true, deleted_at: %DateTime{}}, _user_id), do: true

  defp readable?(%Document{read_only: true, id: id}, user_id),
    do: Scopes.readable_publication?(id, user_id)

  defp readable?(_doc, _user_id), do: false

  defp safe_doc_id(%{"doc_id" => doc_id}) when is_binary(doc_id), do: doc_id
  defp safe_doc_id(_params), do: nil

  def publication_reply({:ok, %Document{} = pub}), do: {:ok, Envelope.doc(pub)}
  def publication_reply({:error, :not_found}), do: {:error, Envelope.error("not_found")}
  def publication_reply({:error, :forbidden}), do: {:error, Envelope.error("forbidden")}
  def publication_reply(_result), do: {:error, Envelope.error("internal")}

  defp load_docs([]), do: %{}

  defp load_docs(ids) do
    Repo.all(from d in Document, where: d.id in ^Enum.uniq(ids)) |> Map.new(&{&1.id, &1})
  end

  # A later write replaced the document, so the upload's stored reply stands in for
  # it: the uploader treats this upsert as its echo and must not see newer content.
  defp superseded_upload?(event, docs) do
    event.kind == "upsert" and event.upload_id != nil and docs[event.doc_id].seq > event.seq
  end

  defp load_upload_replies([]), do: %{}

  defp load_upload_replies(events) do
    upload_ids = Enum.uniq(for e <- events, do: e.upload_id)

    Repo.all(from u in UploadResult, where: u.upload_id in ^upload_ids)
    |> Map.new(&{{&1.upload_id, &1.doc_id, &1.reply["seq"]}, &1.reply})
  end

  defp doc_as_of(event, docs, replies) do
    Map.get(replies, {event.upload_id, event.doc_id, event.seq}, docs[event.doc_id])
  end

  # A deleted document's upserts are dropped; its delete event follows at a higher seq.
  defp live?(%Document{deleted_at: nil}), do: true
  defp live?(_doc), do: false
end
