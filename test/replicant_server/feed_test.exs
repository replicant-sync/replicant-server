defmodule ReplicantServer.FeedTest do
  use ReplicantServer.DataCase

  alias Ecto.Adapters.SQL.Sandbox
  alias ReplicantServer.Feed
  alias ReplicantServer.Feed.ChangeEvent

  defp scope, do: "test:#{System.unique_integer([:positive])}"
  defp change, do: %{doc_id: Ecto.UUID.generate(), kind: "upsert", hash: "h"}

  defp record!(scopes) do
    {:ok, result} = Repo.transaction(fn -> Feed.record(scopes, change()) end)
    result
  end

  describe "record/2" do
    test "chains prev_seq per scope" do
      s = scope()
      {seq1, [e1]} = record!([s])
      {seq2, [e2]} = record!([s])
      assert {e1.seq, e1.prev_seq} == {seq1, 0}
      assert seq2 > seq1
      assert e2.prev_seq == seq1
    end

    test "one logical change gets one seq in every scope, each with its own prev_seq" do
      a = scope()
      b = scope()
      {a_seq, _} = record!([a])
      {seq, events} = record!([a, b])

      assert events |> Enum.map(&{&1.scope, &1.seq, &1.prev_seq}) |> Enum.sort() ==
               Enum.sort([{a, seq, a_seq}, {b, seq, 0}])
    end

    test "a change in no scope still takes a seq" do
      assert {seq, []} = record!([])
      assert is_integer(seq)
    end

    test "refuses to run outside a transaction" do
      assert_raise ArgumentError, fn -> Feed.record([scope()], change()) end
    end
  end

  describe "head/1 and changes_since/3" do
    test "an empty scope's head is change_seq's last value" do
      {seq, _} = record!([scope()])
      {:ok, head} = Repo.transaction(fn -> Feed.head(scope()) end)
      assert head >= seq

      assert {:ok, %{events: [], has_more: false, next_cursor: next}} =
               Feed.changes_since(scope(), 0, 500)

      assert next >= seq
    end

    test "pages in seq order and ends at the scope head" do
      s = scope()
      seqs = for _ <- 1..3, do: elem(record!([s]), 0)

      assert {:ok, %{events: page1, has_more: true, next_cursor: c1}} =
               Feed.changes_since(s, 0, 2)

      assert Enum.map(page1, & &1.seq) == Enum.take(seqs, 2)
      assert c1 == Enum.at(seqs, 1)

      assert {:ok, %{events: [last], has_more: false, next_cursor: c2}} =
               Feed.changes_since(s, c1, 2)

      assert last.seq == List.last(seqs)
      assert c2 >= last.seq
    end

    test "never moves a cursor backwards" do
      assert {:ok, %{next_cursor: 9_000_000_000_000}} =
               Feed.changes_since(scope(), 9_000_000_000_000, 500)
    end

    test "a cursor older than the trim watermark is refused" do
      Repo.query!("UPDATE change_feed_state SET trim_watermark = 100 WHERE id = 1")
      assert {:error, :cursor_too_old} = Feed.changes_since(scope(), 99, 500)
      assert {:ok, _} = Feed.changes_since(scope(), 100, 500)
      assert Feed.trim_watermark() == 100
    end
  end

  test "broadcast/2 publishes each event on its scope topic" do
    s = scope()
    Phoenix.PubSub.subscribe(ReplicantServer.PubSub, Feed.topic(s))
    {_seq, [event]} = record!([s])
    Feed.broadcast([event], :the_doc)
    assert_receive {:feed_change, ^event, :the_doc}
  end

  describe "concurrency (real transactions)" do
    setup do
      s = scope()

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from e in ChangeEvent, where: e.scope == ^s)
        end)
      end)

      %{scope: s}
    end

    defp hold_write(scope, parent) do
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            {seq, _} = Feed.record([scope], change())
            send(parent, {:took, seq})

            receive do
              :commit -> seq
            end
          end)
        end)
      end)
    end

    test "a second writer waits for the first to commit, so seqs commit in order", %{scope: s} do
      writer_a = hold_write(s, self())
      assert_receive {:took, seq_a}

      writer_b =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn -> Feed.record([s], change()) end)
          end)
        end)

      refute Task.yield(writer_b, 200)
      send(writer_a.pid, :commit)
      assert {:ok, ^seq_a} = Task.await(writer_a)
      assert {:ok, {seq_b, [event_b]}} = Task.await(writer_b)
      assert seq_b > seq_a
      assert event_b.prev_seq == seq_a
    end

    test "a reader waits for an in-flight writer, then sees its change", %{scope: s} do
      writer = hold_write(s, self())
      assert_receive {:took, seq}

      reader =
        Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> Feed.changes_since(s, 0, 500) end) end)

      refute Task.yield(reader, 200)
      send(writer.pid, :commit)
      Task.await(writer)
      assert {:ok, %{events: [event], next_cursor: next}} = Task.await(reader)
      assert event.seq == seq
      assert next >= seq
    end
  end
end
