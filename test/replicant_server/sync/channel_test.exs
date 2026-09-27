defmodule ReplicantServer.Sync.ChannelTest do
  use ReplicantServer.Sync.ChannelCase

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
end
