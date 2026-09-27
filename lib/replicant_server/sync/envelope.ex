defmodule ReplicantServer.Sync.Envelope do
  @moduledoc "Protocol v2 payload maps. Field names match the Rust client's serde types."

  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Feed.ChangeEvent

  @fatal_codes ~w(update_required auth_invalid account_disabled)

  def doc(%Document{} = d) do
    %{
      doc_id: d.id,
      owner_id: d.user_id,
      author_id: d.author_id,
      read_only: d.read_only,
      source_doc_id: d.source_doc_id,
      derived_from: d.derived_from,
      title: d.title,
      content: d.content,
      hash: d.content_hash,
      seq: d.seq,
      created_at: d.created_at,
      updated_at: d.updated_at
    }
  end

  def change(%ChangeEvent{} = event, doc, wire_scope) do
    %{
      scope: wire_scope,
      seq: event.seq,
      prev_seq: event.prev_seq,
      doc_id: event.doc_id,
      kind: event.kind,
      doc: if(event.kind == "upsert" and match?(%Document{}, doc), do: doc(doc)),
      client_id: event.client_id,
      upload_id: event.upload_id
    }
  end

  def error(code, extra \\ %{}) do
    Map.merge(%{code: code, is_fatal: code in @fatal_codes}, extra)
  end
end
