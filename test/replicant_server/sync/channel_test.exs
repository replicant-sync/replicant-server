defmodule ReplicantServer.Sync.ChannelTest do
  use ReplicantServer.Sync.ChannelCase

  alias ReplicantServer.Documents
  alias ReplicantServer.Sync.{Channel, Socket}

  setup do
    %{ctx: mint_user("channel@example.com")}
  end

  describe "socket connect" do
    test "a v1 client (no protocol_version) is refused" do
      assert {:error, :update_required} = connect(Socket, %{})
      assert {:error, :update_required} = connect(Socket, %{"email" => "old@example.com"})
    end

    test "a v2 client is accepted with its version and client id" do
      client_id = Ecto.UUID.generate()

      assert {:ok, socket} =
               connect(Socket, %{"protocol_version" => "2", "client_id" => client_id})

      assert socket.assigns.protocol_version == 2
      assert socket.assigns.client_id == client_id
    end

    test "a malformed client id is dropped" do
      assert {:ok, socket} = connect(Socket, %{"protocol_version" => "2", "client_id" => "nope"})
      assert socket.assigns.client_id == nil
    end

    test "any other protocol version gets update_required" do
      assert {:error, :update_required} = connect(Socket, %{"protocol_version" => "3"})
      assert {:error, :update_required} = connect(Socket, %{"protocol_version" => "not-a-number"})
    end

    test "v1 topics have no route" do
      assert Socket.__channel__("sync:user:abc") == nil
      assert Socket.__channel__("sync:public") == nil
      assert {Channel, _opts} = Socket.__channel__("sync:v2")
    end

    test "a refused connect over the real websocket transport path returns HTTP 426" do
      conn =
        build_conn()
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("sec-websocket-version", "13")
        |> put_req_header("sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16)))
        |> get("/socket/websocket")

      assert conn.status == 426
      assert Jason.decode!(conn.resp_body) == %{"code" => "update_required", "is_fatal" => true}
    end
  end

  describe "join sync:v2" do
    test "authenticates and reports the protocol version", %{ctx: ctx} do
      assert {:ok, reply, socket} = join_sync(ctx)
      assert reply == %{user_id: ctx.user.id, protocol_version: 2}
      assert socket.assigns.user_id == ctx.user.id
    end

    test "a bad signature gets auth_invalid (fatal)", %{ctx: ctx} do
      params = %{auth_params(ctx) | "signature" => "bad"}
      assert {:error, %{code: "auth_invalid", is_fatal: true}} = join_sync(ctx, params: params)
    end

    test "an expired timestamp gets transient clock_skew", %{ctx: ctx} do
      params = auth_params(ctx, System.system_time(:second) - 600)
      assert {:error, %{code: "clock_skew", is_fatal: false}} = join_sync(ctx, params: params)
    end

    test "missing credentials get auth_invalid", %{ctx: ctx} do
      assert {:error, %{code: "auth_invalid"}} = join_sync(ctx, params: %{})
    end

    test "a credential with no user gets auth_invalid", %{ctx: ctx} do
      unenrolled = %{ctx | credential: insert_credential(nil)}
      assert {:error, %{code: "auth_invalid", is_fatal: true}} = join_sync(unenrolled)
    end
  end

  describe "get_changes_since and pushes" do
    setup %{ctx: ctx} do
      {:ok, _, socket} = join_sync(ctx)
      %{socket: socket}
    end

    defp catch_up(socket, scope) do
      ref =
        Phoenix.ChannelTest.push(socket, "get_changes_since", %{
          "scope" => scope,
          "cursor" => 0,
          "limit" => 500
        })

      assert_reply ref, :ok, page
      page
    end

    test "replies with a page, then pushes changes for that scope", %{ctx: ctx, socket: socket} do
      assert %{changes: [], has_more: false} = catch_up(socket, "own")

      {:ok, doc} =
        Documents.create_document(ctx.user.id, %{id: Ecto.UUID.generate(), content: %{"t" => 1}})

      id = doc.id

      assert_push "change", %{
        scope: "own",
        kind: "upsert",
        doc_id: ^id,
        doc: %{doc_id: ^id},
        client_id: nil
      }
    end

    test "does not push scopes the client has not caught up", %{ctx: ctx} do
      {:ok, _} = Documents.create_document(ctx.user.id, %{id: Ecto.UUID.generate(), content: %{}})
      refute_push "change", _
    end

    test "does not push other users' own scopes", %{socket: socket} do
      catch_up(socket, "own")
      other = mint_user("channel-other@example.com")

      {:ok, _} =
        Documents.create_document(other.user.id, %{id: Ecto.UUID.generate(), content: %{}})

      refute_push "change", _
    end

    test "an unknown scope is subscription_forbidden", %{socket: socket} do
      ref =
        Phoenix.ChannelTest.push(socket, "get_changes_since", %{
          "scope" => "collection:nope",
          "cursor" => 0
        })

      assert_reply ref, :error, %{
        code: "subscription_forbidden",
        is_fatal: false,
        scope: "collection:nope"
      }
    end

    test "unknown events and missing scopes are validation", %{socket: socket} do
      ref = Phoenix.ChannelTest.push(socket, "request_full_sync", %{})
      assert_reply ref, :error, %{code: "validation"}
      ref = Phoenix.ChannelTest.push(socket, "get_changes_since", %{"cursor" => 0})
      assert_reply ref, :error, %{code: "validation"}
    end

    test "get_snapshot replies and subscribes the scope", %{ctx: ctx, socket: socket} do
      ref = Phoenix.ChannelTest.push(socket, "get_snapshot", %{"scope" => "own"})
      assert_reply ref, :ok, %{docs: [], snapshot_seq: _, next_page_token: nil}
      {:ok, _} = Documents.create_document(ctx.user.id, %{id: Ecto.UUID.generate(), content: %{}})
      assert_push "change", %{scope: "own", kind: "upsert"}
    end
  end

  describe "upload" do
    test "the uploader gets the reply and its own change as a push", %{ctx: ctx} do
      client_id = Ecto.UUID.generate()
      {:ok, _, socket} = join_sync(ctx, client_id: client_id)

      ref =
        Phoenix.ChannelTest.push(socket, "get_changes_since", %{
          "scope" => "own",
          "cursor" => 0,
          "limit" => 500
        })

      assert_reply ref, :ok, _

      doc_id = Ecto.UUID.generate()
      upload_id = Ecto.UUID.generate()

      ref =
        Phoenix.ChannelTest.push(socket, "upload", %{
          "upload_id" => upload_id,
          "doc_id" => doc_id,
          "kind" => "create",
          "payload" => %{"title" => "Mine"}
        })

      assert_reply ref, :ok, %{doc_id: ^doc_id, seq: seq}

      assert_push "change", %{
        scope: "own",
        kind: "upsert",
        seq: ^seq,
        doc_id: ^doc_id,
        upload_id: ^upload_id,
        client_id: ^client_id
      }
    end
  end

  describe "publication RPCs" do
    test "publish replies with the publication; unknown ids are not_found", %{ctx: ctx} do
      {:ok, _, socket} = join_sync(ctx)

      {:ok, source} =
        Documents.create_document(ctx.user.id, %{id: Ecto.UUID.generate(), content: %{"t" => 1}})

      source_id = source.id

      ref = Phoenix.ChannelTest.push(socket, "publish", %{"source_doc_id" => source.id})
      assert_reply ref, :ok, %{read_only: true, source_doc_id: ^source_id, doc_id: pub_id}

      ref =
        Phoenix.ChannelTest.push(socket, "unpublish", %{"publication_id" => Ecto.UUID.generate()})

      assert_reply ref, :error, %{code: "not_found", is_fatal: false}

      ref = Phoenix.ChannelTest.push(socket, "publish_update", %{"publication_id" => pub_id})
      assert_reply ref, :ok, %{doc_id: ^pub_id}
    end

    test "a non-string id replies validation and does not crash the channel", %{ctx: ctx} do
      {:ok, _, socket} = join_sync(ctx)

      ref = Phoenix.ChannelTest.push(socket, "publish", %{"source_doc_id" => 123})
      assert_reply ref, :error, %{code: "validation", is_fatal: false}

      ref =
        Phoenix.ChannelTest.push(socket, "publish_update", %{
          "publication_id" => %{"nope" => true}
        })

      assert_reply ref, :error, %{code: "validation", is_fatal: false}

      ref = Phoenix.ChannelTest.push(socket, "unpublish", %{})
      assert_reply ref, :error, %{code: "validation", is_fatal: false}
    end
  end
end
