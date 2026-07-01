defmodule ReplicantServer.DocumentsBroadcastTest do
  @moduledoc """
  Tests that Documents context mutations broadcast to sync channel topics.

  These verify the web UI → sync client broadcast path:
  when a document is edited via LiveView, the change should be
  broadcast on the appropriate sync:* Phoenix Channel topic so
  connected Replicant clients receive it in real time.
  """
  use ReplicantServer.DataCase

  alias ReplicantServer.{Auth, Accounts, Documents}

  @endpoint ReplicantServerWeb.Endpoint

  setup do
    email = "broadcast-test@example.com"
    user_id = Auth.deterministic_user_id(email)
    {:ok, _user} = Accounts.get_or_create_user(email)
    %{user_id: user_id, email: email}
  end

  describe "replace_content broadcasts to sync channels" do
    test "broadcasts document_updated to user sync channel", %{user_id: user_id} do
      # Create a user document
      {:ok, doc} =
        Documents.create_document(user_id, %{
          "id" => Ecto.UUID.generate(),
          "content" => %{"title" => "Original", "data" => "test"}
        })

      # Subscribe to the user's sync channel topic
      @endpoint.subscribe("sync:user:#{user_id}")

      # Simulate web UI edit
      {:ok, _updated} = Documents.replace_content(doc, %{"title" => "Edited via web", "data" => "test"})

      # Assert broadcast arrived on sync channel
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sync:user:" <> _,
        event: "document_updated",
        payload: payload
      }

      assert payload.id == doc.id
      assert payload.sync_revision == 2
      assert is_list(payload.patch)
      assert payload.content_hash != nil
    end

    test "broadcasts document_updated to public sync channel for public docs" do
      # Create a public document (no user_id)
      {:ok, doc} =
        Documents.create_public_document(%{
          "content" => %{"title" => "Public Original"}
        })

      # Subscribe to public sync channel
      @endpoint.subscribe("sync:public")

      # Simulate web UI edit
      {:ok, _updated} = Documents.replace_content(doc, %{"title" => "Public Edited"})

      # Assert broadcast arrived on sync:public
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sync:public",
        event: "document_updated",
        payload: payload
      }

      assert payload.id == doc.id
      assert payload.sync_revision == 2
      assert is_list(payload.patch)
    end

    test "broadcast patch is JSON-serializable with RFC 6902 op fields", %{user_id: user_id} do
      {:ok, doc} =
        Documents.create_document(user_id, %{
          "id" => Ecto.UUID.generate(),
          "content" => %{"title" => "Before", "count" => 1}
        })

      @endpoint.subscribe("sync:user:#{user_id}")

      {:ok, _updated} = Documents.replace_content(doc, %{"title" => "After", "count" => 2})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "document_updated",
        payload: payload
      }

      # Patch must be a list of plain maps (not Jsonpatch.Operation.* structs)
      assert is_list(payload.patch)
      assert length(payload.patch) > 0

      for op <- payload.patch do
        assert is_map(op), "patch operation must be a plain map"
        assert Map.has_key?(op, :op), "patch operation must have :op key"
        assert op.op in ["add", "remove", "replace", "move", "copy", "test"]
        assert Map.has_key?(op, :path), "patch operation must have :path key"
      end

      # Must be JSON-encodable (would fail with Jsonpatch structs)
      assert {:ok, _json} = Jason.encode(payload)
    end

    test "does not broadcast when content is unchanged", %{user_id: user_id} do
      {:ok, doc} =
        Documents.create_document(user_id, %{
          "id" => Ecto.UUID.generate(),
          "content" => %{"title" => "Same"}
        })

      @endpoint.subscribe("sync:user:#{user_id}")

      # Replace with identical content
      {:ok, _unchanged} = Documents.replace_content(doc, %{"title" => "Same"})

      # No broadcast should fire
      refute_receive %Phoenix.Socket.Broadcast{event: "document_updated"}, 100
    end
  end

  describe "create_public_document broadcasts to sync:public" do
    test "broadcasts document_created on sync:public" do
      @endpoint.subscribe("sync:public")

      {:ok, doc} =
        Documents.create_public_document(%{
          "content" => %{"title" => "New Public Doc"}
        })

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sync:public",
        event: "document_created",
        payload: payload
      }

      assert payload.id == doc.id
      assert payload.content == %{"title" => "New Public Doc"}
      assert payload.sync_revision == 1
      assert payload.content_hash != nil
    end
  end

  describe "delete_public_document broadcasts to sync:public" do
    test "broadcasts document_deleted on sync:public" do
      {:ok, doc} =
        Documents.create_public_document(%{
          "content" => %{"title" => "To Delete"}
        })

      @endpoint.subscribe("sync:public")

      {:ok, _deleted} = Documents.delete_public_document(doc.id)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sync:public",
        event: "document_deleted",
        payload: payload
      }

      assert payload.id == doc.id
    end
  end
end
