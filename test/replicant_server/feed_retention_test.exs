defmodule ReplicantServer.FeedRetentionTest do
  use ReplicantServer.DataCase

  alias Ecto.Adapters.SQL.Sandbox
  alias ReplicantServer.Feed
  alias ReplicantServer.Feed.{ChangeEvent, Retention, UploadResult}

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400, :second)

  defp event!(scope, seq, inserted_at) do
    Repo.insert!(%ChangeEvent{
      scope: scope,
      seq: seq,
      prev_seq: 0,
      doc_id: Ecto.UUID.generate(),
      kind: "upsert",
      inserted_at: inserted_at
    })
  end

  defp next_seq, do: Repo.query!("SELECT nextval('change_seq')").rows |> hd() |> hd()

  test "trims events older than the window and raises the watermark" do
    base = next_seq()
    old = event!("own:ret", base + 1, days_ago(91))
    recent = event!("own:ret", base + 2, days_ago(1))

    assert {:ok, trimmed} = Feed.trim(90)
    assert trimmed == old.seq
    assert Feed.trim_watermark() == old.seq
    refute Repo.get_by(ChangeEvent, scope: "own:ret", seq: old.seq)
    assert Repo.get_by(ChangeEvent, scope: "own:ret", seq: recent.seq)

    assert {:error, :cursor_too_old} = Feed.changes_since("own:ret", base, 500)
    assert {:ok, %{events: [kept]}} = Feed.changes_since("own:ret", old.seq, 500)
    assert kept.seq == recent.seq
  end

  test "the watermark never moves backwards and nothing to trim changes nothing" do
    Repo.query!("UPDATE change_feed_state SET trim_watermark = 9000000000000 WHERE id = 1")
    event!("own:ret2", next_seq(), days_ago(100))
    assert {:ok, _} = Feed.trim(90)
    assert Feed.trim_watermark() == 9_000_000_000_000
    assert {:ok, nil} = Feed.trim(90)
  end

  test "stored upload replies expire with the window" do
    old =
      Repo.insert!(%UploadResult{
        upload_id: Ecto.UUID.generate(),
        base_hash: "",
        doc_id: Ecto.UUID.generate(),
        reply: %{},
        inserted_at: days_ago(91)
      })

    fresh =
      Repo.insert!(%UploadResult{
        upload_id: Ecto.UUID.generate(),
        base_hash: "",
        doc_id: Ecto.UUID.generate(),
        reply: %{}
      })

    {:ok, _} = Feed.trim(90)
    refute Repo.get_by(UploadResult, upload_id: old.upload_id)
    assert Repo.get_by(UploadResult, upload_id: fresh.upload_id)
  end

  test "the Retention server trims when its timer fires" do
    pid = start_supervised!({Retention, name: :retention_test, first_run_ms: :timer.hours(1)})
    Sandbox.allow(Repo, self(), pid)
    old = event!("own:ret3", next_seq(), days_ago(120))

    send(pid, :trim)
    _ = :sys.get_state(pid)
    refute Repo.get_by(ChangeEvent, scope: "own:ret3", seq: old.seq)
  end
end
