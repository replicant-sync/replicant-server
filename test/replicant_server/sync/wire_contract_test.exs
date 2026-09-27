defmodule ReplicantServer.Sync.WireContractTest do
  use ReplicantServer.Sync.ChannelCase

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Phoenix.Socket.{Message, Reply}
  alias Phoenix.Socket.V2.JSONSerializer
  alias ReplicantServer.{Documents, Repo}

  @golden Path.expand("../../fixtures/wire/v2_frames.json", __DIR__)

  # Field names of the Rust client's serde types (replicant-client src/engine/types.rs).
  @envelope_keys ~w(author_id content created_at derived_from doc_id hash owner_id read_only seq source_doc_id title updated_at)
  @change_keys ~w(client_id doc doc_id kind prev_seq scope seq upload_id)

  @nil_uuid "00000000-0000-0000-0000-000000000000"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @seq_keys ~w(seq prev_seq next_cursor snapshot_seq current_seq)
  @time_keys ~w(created_at updated_at)

  test "v2 frames match the client's wire types" do
    ctx = mint_user("wire@example.com")
    {:ok, join_reply, socket} = join_sync(ctx)
    doc_id = Ecto.UUID.generate()

    ref =
      Phoenix.ChannelTest.push(socket, "get_changes_since", %{
        "scope" => "own",
        "cursor" => 0,
        "limit" => 500
      })

    assert_reply ref, :ok, changes

    ref =
      Phoenix.ChannelTest.push(socket, "upload", %{
        "upload_id" => Ecto.UUID.generate(),
        "doc_id" => doc_id,
        "kind" => "create",
        "payload" => %{"title" => "Wire"}
      })

    assert_reply ref, :ok, uploaded
    assert_push "change", change

    ref =
      Phoenix.ChannelTest.push(socket, "upload", %{
        "upload_id" => Ecto.UUID.generate(),
        "doc_id" => doc_id,
        "kind" => "update",
        "base_hash" => "stale",
        "payload" => []
      })

    assert_reply ref, :error, mismatch

    ref = Phoenix.ChannelTest.push(socket, "get_snapshot", %{"scope" => "own"})
    assert_reply ref, :ok, snapshot

    ref = Phoenix.ChannelTest.push(socket, "get_document", %{"doc_id" => doc_id})
    assert_reply ref, :ok, document

    ref =
      Phoenix.ChannelTest.push(socket, "upload", %{
        "upload_id" => Ecto.UUID.generate(),
        "doc_id" => doc_id,
        "kind" => "delete",
        "payload" => nil
      })

    assert_reply ref, :ok, _
    assert_push "change", delete_change
    assert %{kind: "delete", doc: nil, prev_seq: prev_seq} = delete_change
    assert is_integer(prev_seq)

    ref =
      Phoenix.ChannelTest.push(socket, "get_changes_since", %{
        "scope" => "own",
        "cursor" => 0,
        "limit" => 500
      })

    assert_reply ref, :ok, populated_changes
    assert %{changes: [%{kind: "delete", doc_id: ^doc_id}], has_more: false} = populated_changes

    ref = Phoenix.ChannelTest.push(socket, "get_document", %{"doc_id" => doc_id})
    assert_reply ref, :error, deleted

    assert keys(uploaded) == @envelope_keys
    assert keys(document) == @envelope_keys
    assert keys(change) == @change_keys
    assert keys(change.doc) == @envelope_keys
    assert keys(changes) == ~w(changes has_more next_cursor)
    assert keys(snapshot) == ~w(docs next_page_token snapshot_seq)
    assert keys(join_reply) == ~w(protocol_version user_id)
    assert %{code: "hash_mismatch", is_fatal: false, current_hash: h, current_seq: s} = mismatch
    assert is_binary(h) and is_integer(s)
    assert %{code: "deleted", is_fatal: false, current_seq: ds} = deleted
    assert is_integer(ds)

    # Socket refusal: HTTP 426 refusal body for a stale/missing protocol_version.
    conn =
      build_conn()
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-version", "13")
      |> put_req_header("sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16)))
      |> get("/socket/websocket")

    assert conn.status == 426
    socket_refusal = Jason.decode!(conn.resp_body)
    assert socket_refusal == %{"code" => "update_required", "is_fatal" => true}

    # Join error: bad signature. Channel.join logs a warning on rejection.
    bad_params = %{auth_params(ctx) | "signature" => "bad"}

    {join_result, _log} = with_log(fn -> join_sync(ctx, params: bad_params) end)
    assert {:error, join_error} = join_result
    assert %{code: "auth_invalid", is_fatal: true} = join_error

    # `exists`: re-creating a doc_id that already exists (even once deleted).
    ref =
      Phoenix.ChannelTest.push(socket, "upload", %{
        "upload_id" => Ecto.UUID.generate(),
        "doc_id" => doc_id,
        "kind" => "create",
        "payload" => %{}
      })

    assert_reply ref, :error, exists
    assert %{code: "exists", is_fatal: false, existing_owner: owner} = exists
    assert is_binary(owner)

    # `too_large`: an oversized create payload.
    big = %{"blob" => String.duplicate("a", 1_048_577)}

    ref =
      Phoenix.ChannelTest.push(socket, "upload", %{
        "upload_id" => Ecto.UUID.generate(),
        "doc_id" => Ecto.UUID.generate(),
        "kind" => "create",
        "payload" => big
      })

    assert_reply ref, :error, too_large
    assert %{code: "too_large", is_fatal: false} = too_large

    # `subscription_forbidden`: an unknown scope.
    ref =
      Phoenix.ChannelTest.push(socket, "get_changes_since", %{
        "scope" => "collection:nope",
        "cursor" => 0
      })

    assert_reply ref, :error, subscription_forbidden

    assert %{code: "subscription_forbidden", is_fatal: false, scope: "collection:nope"} =
             subscription_forbidden

    # `validation`: a missing scope.
    ref = Phoenix.ChannelTest.push(socket, "get_changes_since", %{"cursor" => 0})
    assert_reply ref, :error, validation
    assert %{code: "validation", is_fatal: false} = validation

    # F2: a document with an integral float in its content, recorded both as
    # the upload reply that echoes it and read back via get_document, so the
    # client sees exactly what jsonb returns in both places.
    float_doc_id = Ecto.UUID.generate()

    ref =
      Phoenix.ChannelTest.push(socket, "upload", %{
        "upload_id" => Ecto.UUID.generate(),
        "doc_id" => float_doc_id,
        "kind" => "create",
        "payload" => %{"title" => "t", "cents" => 1200.0}
      })

    assert_reply ref, :ok, float_upload
    assert_push "change", _float_change

    ref = Phoenix.ChannelTest.push(socket, "get_document", %{"doc_id" => float_doc_id})
    assert_reply ref, :ok, float_document

    # Publications: publish, publish_update, unpublish (request and reply).
    {:ok, source} =
      Documents.create_document(ctx.user.id, %{
        id: Ecto.UUID.generate(),
        content: %{"title" => "Source"}
      })

    publish_params = %{"source_doc_id" => source.id}
    ref = Phoenix.ChannelTest.push(socket, "publish", publish_params)
    assert_reply ref, :ok, published
    assert %{read_only: true, source_doc_id: source_id} = published
    assert source_id == source.id

    publish_update_params = %{"publication_id" => published.doc_id}
    ref = Phoenix.ChannelTest.push(socket, "publish_update", publish_update_params)
    assert_reply ref, :ok, republished

    unpublish_params = %{"publication_id" => published.doc_id}
    ref = Phoenix.ChannelTest.push(socket, "unpublish", unpublish_params)
    assert_reply ref, :ok, unpublished

    # `cursor_too_old`: trim watermark has advanced past the client's cursor.
    Repo.query!("UPDATE change_feed_state SET trim_watermark = 9000000000000 WHERE id = 1")

    ref =
      Phoenix.ChannelTest.push(socket, "get_changes_since", %{
        "scope" => "own",
        "cursor" => 0,
        "limit" => 500
      })

    assert_reply ref, :error, cursor_too_old
    assert %{code: "cursor_too_old", is_fatal: false, scope: "own"} = cursor_too_old

    frames =
      %{
        "join_reply" => join_reply_frame(:ok, join_reply),
        "join_error_reply" => join_reply_frame(:error, join_error),
        "changes_reply" => reply_frame(:ok, changes),
        "changes_reply_populated" => reply_frame(:ok, populated_changes),
        "upload_reply" => reply_frame(:ok, uploaded),
        "change_push" => push_frame("change", change),
        "change_push_delete" => push_frame("change", delete_change),
        "hash_mismatch_reply" => reply_frame(:error, mismatch),
        "snapshot_reply" => reply_frame(:ok, snapshot),
        "document_reply" => reply_frame(:ok, document),
        "deleted_reply" => reply_frame(:error, deleted),
        "socket_refusal" => socket_refusal,
        "exists_reply" => reply_frame(:error, exists),
        "too_large_reply" => reply_frame(:error, too_large),
        "subscription_forbidden_reply" => reply_frame(:error, subscription_forbidden),
        "validation_reply" => reply_frame(:error, validation),
        "cursor_too_old_reply" => reply_frame(:error, cursor_too_old),
        "float_upload_reply" => reply_frame(:ok, float_upload),
        "float_document_reply" => reply_frame(:ok, float_document),
        "publish_request" => request_frame("publish", publish_params),
        "publish_reply" => reply_frame(:ok, published),
        "publish_update_request" => request_frame("publish_update", publish_update_params),
        "publish_update_reply" => reply_frame(:ok, republished),
        "unpublish_request" => request_frame("unpublish", unpublish_params),
        "unpublish_reply" => reply_frame(:ok, unpublished)
      }
      |> normalize()

    if System.get_env("RECORD_WIRE") do
      File.mkdir_p!(Path.dirname(@golden))
      File.write!(@golden, Jason.encode!(frames, pretty: true) <> "\n")
    end

    assert frames == @golden |> File.read!() |> Jason.decode!()
  end

  defp keys(map), do: map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  # A join's reply ref equals its join_ref: joining is the message that
  # establishes the join_ref in the first place.
  defp join_reply_frame(status, payload) do
    decode(%Reply{join_ref: "1", ref: "1", topic: "sync:v2", status: status, payload: payload})
  end

  defp reply_frame(status, payload) do
    decode(%Reply{join_ref: "1", ref: "2", topic: "sync:v2", status: status, payload: payload})
  end

  # A client request always carries a ref (it expects a matching reply); a
  # server-initiated push never does.
  defp request_frame(event, payload) do
    decode(%Message{join_ref: "1", ref: "2", topic: "sync:v2", event: event, payload: payload})
  end

  defp push_frame(event, payload) do
    decode(%Message{join_ref: "1", ref: nil, topic: "sync:v2", event: event, payload: payload})
  end

  defp decode(frame) do
    {:socket_push, :text, data} = JSONSerializer.encode!(frame)
    data |> IO.iodata_to_binary() |> Jason.decode!()
  end

  # Seq-like values are normalised by rank, not to a single constant: every
  # distinct value seen anywhere in the fixture maps to its ascending
  # position (1, 2, 3, ...), so relationships like `prev_seq < seq` survive
  # normalisation instead of collapsing to indistinguishable 1s.
  defp normalize(frames) do
    ranks =
      frames
      |> collect_seqs()
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Map.new()

    walk(frames, ranks)
  end

  defp collect_seqs(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      if(k in @seq_keys and is_integer(v), do: [v], else: []) ++ collect_seqs(v)
    end)
  end

  defp collect_seqs(list) when is_list(list), do: Enum.flat_map(list, &collect_seqs/1)
  defp collect_seqs(_value), do: []

  defp walk(map, ranks) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, walk(k, v, ranks)} end)

  defp walk(list, ranks) when is_list(list), do: Enum.map(list, &walk(&1, ranks))

  defp walk(value, _ranks) when is_binary(value),
    do: if(value =~ @uuid, do: @nil_uuid, else: value)

  defp walk(value, _ranks), do: value

  defp walk(key, value, ranks) when key in @seq_keys and is_integer(value),
    do: Map.fetch!(ranks, value)

  defp walk(key, value, _ranks) when key in @time_keys and is_binary(value),
    do: "2026-01-01T00:00:00.000000Z"

  defp walk(_key, value, ranks), do: walk(value, ranks)
end
