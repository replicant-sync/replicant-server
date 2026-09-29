defmodule ReplicantServer.Feed do
  @moduledoc """
  Per-scope change feed. A logical change takes one `seq` from `change_seq`
  and appends one `ChangeEvent` per affected scope.

  Write recipe, inside one `Repo.transaction`: lock the document row (if one
  exists), `record/2`, commit, then `broadcast/2`. `record/2` takes the scope
  advisory locks before `nextval`, so commits within a scope happen in `seq`
  order and `head/1` never returns a value past an uncommitted change. `head/1`
  takes the same lock in shared mode, so concurrent reads do not block each other.
  """

  import Ecto.Query

  alias ReplicantServer.Repo
  alias ReplicantServer.Feed.{ChangeEvent, UploadResult}

  @retention_days 90

  def retention_days, do: @retention_days

  def lock_scopes([]), do: :ok

  def lock_scopes(scopes) do
    require_transaction!()

    %{rows: rows} =
      Repo.query!(
        "SELECT DISTINCT hashtext(s) AS key FROM unnest($1::text[]) AS s ORDER BY key",
        [Enum.uniq(scopes)]
      )

    Enum.each(rows, fn [key] -> Repo.query!("SELECT pg_advisory_xact_lock($1)", [key]) end)
  end

  def record(scopes, attrs) do
    require_transaction!()
    scopes = Enum.uniq(scopes)
    lock_scopes(scopes)
    %{rows: [[seq]]} = Repo.query!("SELECT nextval('change_seq')")

    events =
      Enum.map(scopes, fn scope ->
        prev_seq =
          Repo.one(from e in ChangeEvent, where: e.scope == ^scope, select: max(e.seq)) || 0

        Repo.insert!(%ChangeEvent{
          scope: scope,
          seq: seq,
          prev_seq: prev_seq,
          doc_id: attrs.doc_id,
          kind: attrs.kind,
          hash: attrs[:hash],
          client_id: attrs[:client_id],
          upload_id: attrs[:upload_id]
        })
      end)

    {seq, events}
  end

  # Readers take the scope lock shared: they wait for in-flight writers and block new
  # ones until commit, but not each other.
  def head(scope) do
    require_transaction!()
    Repo.query!("SELECT pg_advisory_xact_lock_shared(hashtext($1))", [scope])

    %{rows: [[value]]} =
      Repo.query!("SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM change_seq")

    value
  end

  def changes_since(scope, cursor, limit) do
    Repo.transaction(fn ->
      head = head(scope)

      events =
        Repo.all(
          from e in ChangeEvent,
            where: e.scope == ^scope and e.seq > ^cursor,
            order_by: e.seq,
            limit: ^(limit + 1)
        )

      # Read after the events so a trim that commits mid-read is still detected.
      # A cursor past the head comes from another database (a restore or reset).
      if cursor < trim_watermark() or cursor > head, do: Repo.rollback(:cursor_too_old)

      {page, rest} = Enum.split(events, limit)
      has_more = rest != []
      next_cursor = if has_more, do: List.last(page).seq, else: head
      %{events: page, next_cursor: next_cursor, has_more: has_more}
    end)
  end

  def trim(days \\ @retention_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Repo.transaction(fn ->
      cutoff_seq =
        Repo.one(from e in ChangeEvent, where: e.inserted_at < ^cutoff, select: max(e.seq))

      if cutoff_seq do
        Repo.delete_all(from e in ChangeEvent, where: e.seq <= ^cutoff_seq)

        Repo.update_all(
          from(s in "change_feed_state", where: s.id == 1 and s.trim_watermark < ^cutoff_seq),
          set: [trim_watermark: cutoff_seq]
        )
      end

      Repo.delete_all(from u in UploadResult, where: u.inserted_at < ^cutoff)
      cutoff_seq
    end)
  end

  def trim_watermark do
    Repo.one!(from s in "change_feed_state", where: s.id == 1, select: s.trim_watermark)
  end

  def topic(scope), do: "feed:" <> scope

  def broadcast(events, doc) do
    Enum.each(events, fn event ->
      Phoenix.PubSub.broadcast(
        ReplicantServer.PubSub,
        topic(event.scope),
        {:feed_change, event, doc}
      )
    end)
  end

  defp require_transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Feed writes and locks must run inside Repo.transaction")
  end
end
