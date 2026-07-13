defmodule ReplicantServer.Sync.ChannelTest do
  use ReplicantServer.Sync.ChannelCase

  alias ReplicantServer.Auth

  setup do
    email = "test@example.com"
    {:ok, user} = ReplicantServer.Accounts.get_or_create_user(email)
    {:ok, credential} = mint_credential_for(user)
    timestamp = System.system_time(:second)
    signature = Auth.create_signature(credential.secret, timestamp, email, credential.api_key)

    %{
      credential: credential,
      email: email,
      user_id: user.id,
      timestamp: timestamp,
      signature: signature
    }
  end

  defp mint_credential_for(user) do
    creds = Auth.generate_credentials()

    %ReplicantServer.Auth.ApiCredential{}
    |> ReplicantServer.Auth.ApiCredential.changeset(
      Map.merge(creds, %{name: "test-device", user_id: user.id})
    )
    |> ReplicantServer.Repo.insert()
  end

  defp join_user_channel(context) do
    {:ok, _reply, socket} =
      socket(ReplicantServer.Sync.Socket, "user_socket", %{})
      |> subscribe_and_join(ReplicantServer.Sync.Channel, "sync:user:#{context.user_id}", %{
        "email" => context.email,
        "api_key" => context.credential.api_key,
        "signature" => context.signature,
        "timestamp" => context.timestamp
      })

    socket
  end

  describe "join" do
    test "authenticates and joins with valid credentials", %{
      credential: cred,
      email: email,
      user_id: user_id,
      timestamp: timestamp,
      signature: signature
    } do
      {:ok, reply, socket} =
        socket(ReplicantServer.Sync.Socket, "user_socket", %{})
        |> subscribe_and_join(ReplicantServer.Sync.Channel, "sync:user:#{user_id}", %{
          "email" => email,
          "api_key" => cred.api_key,
          "signature" => signature,
          "timestamp" => timestamp
        })

      assert reply.user_id == user_id
      assert socket.assigns.user_id == user_id
    end

    test "rejects invalid signature", %{
      credential: cred,
      email: email,
      user_id: user_id,
      timestamp: timestamp
    } do
      assert {:error, %{reason: "invalid_signature"}} =
               socket(ReplicantServer.Sync.Socket, "user_socket", %{})
               |> subscribe_and_join(ReplicantServer.Sync.Channel, "sync:user:#{user_id}", %{
                 "email" => email,
                 "api_key" => cred.api_key,
                 "signature" => "invalid_signature",
                 "timestamp" => timestamp
               })
    end

    test "rejects missing params" do
      assert {:error, %{reason: "missing_params"}} =
               socket(ReplicantServer.Sync.Socket, "user_socket", %{})
               |> subscribe_and_join(ReplicantServer.Sync.Channel, "sync:public", %{})
    end

    test "join on another user's topic is rejected", %{
      credential: cred,
      email: email,
      timestamp: timestamp,
      signature: signature
    } do
      assert {:error, %{reason: "topic_user_mismatch"}} =
               socket(ReplicantServer.Sync.Socket, "user_socket", %{})
               |> subscribe_and_join(
                 ReplicantServer.Sync.Channel,
                 "sync:user:#{Ecto.UUID.generate()}",
                 %{
                   "email" => email,
                   "api_key" => cred.api_key,
                   "signature" => signature,
                   "timestamp" => timestamp
                 }
               )
    end

    test "a credential with no user_id cannot resolve identity", %{timestamp: timestamp} do
      {:ok, legacy} = Auth.create_credential("legacy-shared")
      email = "anyone@example.com"
      signature = Auth.create_signature(legacy.secret, timestamp, email, legacy.api_key)

      assert {:error, %{reason: "credential_not_enrolled"}} =
               socket(ReplicantServer.Sync.Socket, "user_socket", %{})
               |> subscribe_and_join(
                 ReplicantServer.Sync.Channel,
                 "sync:user:#{Ecto.UUID.generate()}",
                 %{
                   "email" => email,
                   "api_key" => legacy.api_key,
                   "signature" => signature,
                   "timestamp" => timestamp
                 }
               )
    end

    test "a credential with no user_id cannot join sync:public", %{timestamp: timestamp} do
      {:ok, legacy} = Auth.create_credential("legacy-shared")
      email = "anyone@example.com"
      signature = Auth.create_signature(legacy.secret, timestamp, email, legacy.api_key)

      assert {:error, %{reason: "credential_not_enrolled"}} =
               socket(ReplicantServer.Sync.Socket, "user_socket", %{})
               |> subscribe_and_join(
                 ReplicantServer.Sync.Channel,
                 "sync:public",
                 %{
                   "email" => email,
                   "api_key" => legacy.api_key,
                   "signature" => signature,
                   "timestamp" => timestamp
                 }
               )
    end
  end

  describe "create_document" do
    setup context do
      %{socket: join_user_channel(context)}
    end

    test "creates document and broadcasts", %{socket: socket} do
      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Test Document"}
        })

      assert_reply ref, :ok, %{id: ^doc_id, sync_revision: 1}
      assert_broadcast "document_created", %{id: ^doc_id}
    end

    test "create envelope carries attribution", %{socket: socket} do
      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Attributed"}
        })

      # test@example.com has no display_name -> email local part
      assert_reply ref, :ok, %{
        id: ^doc_id,
        author_name: "test",
        visibility: "private",
        provenance: %{}
      }

      assert_broadcast "document_created", %{
        id: ^doc_id,
        author_name: "test",
        visibility: "private",
        user_id: user_id
      }

      assert user_id != nil
    end

    test "ignores client-supplied attribution fields", %{socket: socket} do
      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Spoofed"},
          "visibility" => "public",
          "author_name" => "Mallory",
          "provenance" => %{"forged" => true},
          "user_id" => Ecto.UUID.generate()
        })

      assert_reply ref, :ok, %{id: ^doc_id, author_name: "test", visibility: "private"}
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
      socket = join_user_channel(context)

      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Original"}
        })

      assert_reply ref, :ok, %{content_hash: content_hash}

      %{socket: socket, doc_id: doc_id, content_hash: content_hash}
    end

    test "updates document with valid content_hash", %{
      socket: socket,
      doc_id: doc_id,
      content_hash: content_hash
    } do
      ref =
        push(socket, "update_document", %{
          "id" => doc_id,
          "patch" => [%{op: "replace", path: "/title", value: "Updated"}],
          "content_hash" => content_hash
        })

      assert_reply ref, :ok, %{sync_revision: 2}
      assert_broadcast "document_updated", %{id: ^doc_id, sync_revision: 2}
    end

    test "returns hash_mismatch for wrong content_hash", %{socket: socket, doc_id: doc_id} do
      ref =
        push(socket, "update_document", %{
          "id" => doc_id,
          "patch" => [%{op: "replace", path: "/title", value: "Updated"}],
          "content_hash" => "wrong_hash"
        })

      assert_reply ref, :error, %{reason: "hash_mismatch", current_revision: 1}
    end
  end

  describe "owned public documents" do
    setup context do
      socket = join_user_channel(context)

      {:ok, doc} =
        ReplicantServer.Documents.create_document(context.user_id, %{
          "id" => UUID.uuid4(),
          "content" => %{"title" => "Public tuning"}
        })

      {:ok, doc} =
        doc
        |> Ecto.Changeset.change(visibility: "public")
        |> ReplicantServer.Repo.update()

      Phoenix.PubSub.subscribe(ReplicantServer.PubSub, "sync:public")
      %{socket: socket, doc: doc}
    end

    test "updating an owned public document broadcasts to sync:public", %{
      socket: socket,
      doc: doc
    } do
      doc_id = doc.id

      ref =
        push(socket, "update_document", %{
          "id" => doc_id,
          "patch" => [%{op: "replace", path: "/title", value: "Renamed"}],
          "content_hash" => doc.content_hash
        })

      assert_reply ref, :ok, _

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sync:public",
        event: "document_updated",
        payload: %{id: ^doc_id}
      }
    end

    test "deleting an owned public document broadcasts to sync:public", %{
      socket: socket,
      doc: doc
    } do
      doc_id = doc.id

      ref = push(socket, "delete_document", %{"id" => doc_id})

      assert_reply ref, :ok

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sync:public",
        event: "document_deleted",
        payload: %{id: ^doc_id}
      }
    end

    test "a private document does not broadcast to sync:public", %{socket: socket} do
      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{
          "id" => doc_id,
          "content" => %{"title" => "Private"}
        })

      assert_reply ref, :ok, _
      refute_receive %Phoenix.Socket.Broadcast{topic: "sync:public", event: "document_created"}
    end
  end

  describe "full_sync" do
    setup context do
      socket = join_user_channel(context)

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

    test "full sync documents carry attribution", %{socket: socket} do
      ref = push(socket, "request_full_sync", %{})
      assert_reply ref, :ok, %{documents: docs}

      assert Enum.all?(docs, fn d ->
               Map.has_key?(d, :author_name) and d.visibility in ["private", "public"] and
                 Map.has_key?(d, :provenance)
             end)
    end
  end

  describe "get_changes_since" do
    setup context do
      socket = join_user_channel(context)

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

    test "events carry the document's attribution", %{socket: socket} do
      doc_id = UUID.uuid4()

      ref =
        push(socket, "create_document", %{"id" => doc_id, "content" => %{"title" => "Evented"}})

      assert_reply ref, :ok, _

      ref = push(socket, "get_changes_since", %{"last_sequence" => 0})
      assert_reply ref, :ok, %{events: events}

      event = Enum.find(events, &(&1.id == doc_id))
      assert event.author_name == "test"
      assert event.visibility == "private"
      assert event.provenance == %{}
      refute Map.has_key?(event, :user_id)
    end
  end
end
