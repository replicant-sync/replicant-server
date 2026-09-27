defmodule ReplicantServer.Sync.Protocol do
  @moduledoc "Request handlers for the v2 channel. Each returns a Phoenix reply: `{:ok, map}` or `{:error, map}`."

  import Ecto.Query

  alias ReplicantServer.{Feed, Repo}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Sync.Envelope

  @max_page 500

  def changes_since(scope_key, wire_scope, %{"cursor" => cursor} = params)
      when is_integer(cursor) and cursor >= 0 do
    case Feed.changes_since(scope_key, cursor, page_limit(params["limit"])) do
      {:ok, page} ->
        docs = load_docs(for e <- page.events, e.kind == "upsert", do: e.doc_id)

        changes =
          for event <- page.events,
              event.kind != "upsert" or live?(docs[event.doc_id]),
              do: Envelope.change(event, docs[event.doc_id], wire_scope)

        {:ok, %{changes: changes, next_cursor: page.next_cursor, has_more: page.has_more}}

      {:error, :cursor_too_old} ->
        {:error, Envelope.error("cursor_too_old", %{scope: wire_scope})}
    end
  end

  def changes_since(_scope_key, wire_scope, _params) do
    {:error, Envelope.error("validation", %{scope: wire_scope})}
  end

  defp page_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_page)
  defp page_limit(_limit), do: @max_page

  defp load_docs([]), do: %{}

  defp load_docs(ids) do
    Repo.all(from d in Document, where: d.id in ^Enum.uniq(ids)) |> Map.new(&{&1.id, &1})
  end

  # A deleted document's upserts are dropped; its delete event follows at a higher seq.
  defp live?(%Document{deleted_at: nil}), do: true
  defp live?(_doc), do: false
end
