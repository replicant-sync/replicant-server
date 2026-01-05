defmodule ReplicantServerWeb.SyncChannelTest do
  use ReplicantServerWeb.ChannelCase

  alias ReplicantServer.Auth

  setup do
    {:ok, credential} = Auth.create_credential("Test App")
    email = "test@example.com"
    timestamp = System.system_time(:second)
    signature = Auth.create_signature(credential.secret, timestamp, email, credential.api_key)

    %{
      credential: credential,
      email: email,
      timestamp: timestamp,
      signature: signature
    }
  end

  describe "join" do
    test "authenticates and joins with valid credentials", %{
      credential: cred,
      email: email,
      timestamp: timestamp,
      signature: signature
    } do
      {:ok, reply, socket} =
        socket(ReplicantServerWeb.UserSocket, "user_socket", %{})
        |> subscribe_and_join(ReplicantServerWeb.SyncChannel, "sync:main", %{
          "email" => email,
          "api_key" => cred.api_key,
          "signature" => signature,
          "timestamp" => timestamp
        })

      assert reply.user_id != nil
      assert socket.assigns.user_id != nil
      assert socket.assigns.email == email
    end

    test "rejects invalid signature", %{credential: cred, email: email, timestamp: timestamp} do
      assert {:error, %{reason: "invalid_signature"}} =
               socket(ReplicantServerWeb.UserSocket, "user_socket", %{})
               |> subscribe_and_join(ReplicantServerWeb.SyncChannel, "sync:main", %{
                 "email" => email,
                 "api_key" => cred.api_key,
                 "signature" => "invalid_signature",
                 "timestamp" => timestamp
               })
    end

    test "rejects missing params" do
      assert {:error, %{reason: "missing_params"}} =
               socket(ReplicantServerWeb.UserSocket, "user_socket", %{})
               |> subscribe_and_join(ReplicantServerWeb.SyncChannel, "sync:main", %{})
    end
  end

  describe "create_document" do
    setup context do
      {:ok, _reply, socket} =
        socket(ReplicantServerWeb.UserSocket, "user_socket", %{})
        |> subscribe_and_join(ReplicantServerWeb.SyncChannel, "sync:main", %{
          "email" => context.email,
          "api_key" => context.credential.api_key,
          "signature" => context.signature,
          "timestamp" => context.timestamp
        })

      %{socket: socket}
    end

    test "creates document and broadcasts", %{socket: socket} do
      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Test Document"}
        })

      assert_reply ref, :ok, %{document_id: ^doc_id, sync_revision: 1}
      assert_broadcast "document_created", %{document_id: ^doc_id}
    end

    test "returns conflict for duplicate ID", %{socket: socket} do
      doc_id = UUID.uuid4()

      ref1 =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "First"}
        })

      assert_reply ref1, :ok, _

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Second"}
        })

      assert_reply ref, :error, %{reason: "conflict", existing_id: ^doc_id}
    end
  end

  describe "update_document" do
    setup context do
      {:ok, _reply, socket} =
        socket(ReplicantServerWeb.UserSocket, "user_socket", %{})
        |> subscribe_and_join(ReplicantServerWeb.SyncChannel, "sync:main", %{
          "email" => context.email,
          "api_key" => context.credential.api_key,
          "signature" => context.signature,
          "timestamp" => context.timestamp
        })

      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Original"}
        })

      assert_reply ref, :ok, _

      %{socket: socket, doc_id: doc_id}
    end

    test "updates document with valid revision", %{socket: socket, doc_id: doc_id} do
      ref =
        push(socket, "update_document", %{
          "document_id" => doc_id,
          "patch" => [%{op: "replace", path: "/title", value: "Updated"}],
          "expected_revision" => 1
        })

      assert_reply ref, :ok, %{sync_revision: 2}
      assert_broadcast "document_updated", %{document_id: ^doc_id, sync_revision: 2}
    end

    test "returns version_mismatch for wrong revision", %{socket: socket, doc_id: doc_id} do
      ref =
        push(socket, "update_document", %{
          "document_id" => doc_id,
          "patch" => [%{op: "replace", path: "/title", value: "Updated"}],
          "expected_revision" => 999
        })

      assert_reply ref, :error, %{reason: "version_mismatch", current_revision: 1}
    end
  end

  describe "full_sync" do
    setup context do
      {:ok, _reply, socket} =
        socket(ReplicantServerWeb.UserSocket, "user_socket", %{})
        |> subscribe_and_join(ReplicantServerWeb.SyncChannel, "sync:main", %{
          "email" => context.email,
          "api_key" => context.credential.api_key,
          "signature" => context.signature,
          "timestamp" => context.timestamp
        })

      # Create some documents
      refs =
        for i <- 1..3 do
          push(socket, "create_document", %{
            "id" => UUID.uuid4(),
            "content" => %{"title" => "Doc #{i}"}
          })
        end

      for ref <- refs do
        assert_reply ref, :ok, _
      end

      %{socket: socket}
    end

    test "returns all user documents", %{socket: socket} do
      ref = push(socket, "request_full_sync", %{})
      assert_reply ref, :ok, %{documents: docs, latest_sequence: seq}
      assert length(docs) == 3
      assert seq > 0
    end
  end

  describe "get_changes_since" do
    setup context do
      {:ok, _reply, socket} =
        socket(ReplicantServerWeb.UserSocket, "user_socket", %{})
        |> subscribe_and_join(ReplicantServerWeb.SyncChannel, "sync:main", %{
          "email" => context.email,
          "api_key" => context.credential.api_key,
          "signature" => context.signature,
          "timestamp" => context.timestamp
        })

      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Test"}
        })

      assert_reply ref, :ok, _

      %{socket: socket, doc_id: doc_id}
    end

    test "returns events since sequence", %{socket: socket} do
      ref = push(socket, "get_changes_since", %{"last_sequence" => 0})
      assert_reply ref, :ok, %{events: events, latest_sequence: _}
      assert length(events) >= 1
      assert hd(events).event_type == "create"
    end
  end
end
