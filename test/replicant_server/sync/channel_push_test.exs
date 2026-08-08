defmodule ReplicantServer.Sync.ChannelPushTest do
  @moduledoc """
  Verifies that Documents context broadcasts reach a JOINED channel as pushes.

  Context writes (e.g. a host web app saving through `Documents`) broadcast
  with plain `Phoenix.PubSub.broadcast`, which delivers to the channel process
  rather than the transport fastlane — the channel must forward those to the
  client via `handle_out/3`, not crash.
  """
  use ReplicantServer.Sync.ChannelCase

  alias ReplicantServer.{Auth, Documents}

  setup do
    email = "channel-push@example.com"
    {:ok, user} = ReplicantServer.Accounts.get_or_create_user(email)

    creds = Auth.generate_credentials()

    {:ok, credential} =
      %ReplicantServer.Auth.ApiCredential{}
      |> ReplicantServer.Auth.ApiCredential.changeset(
        Map.merge(creds, %{name: "test-device", user_id: user.id})
      )
      |> ReplicantServer.Repo.insert()

    timestamp = System.system_time(:second)
    signature = Auth.create_signature(credential.secret, timestamp, email, credential.api_key)

    {:ok, _reply, socket} =
      socket(ReplicantServer.Sync.Socket, "user_socket", %{})
      |> subscribe_and_join(ReplicantServer.Sync.Channel, "sync:user:#{user.id}", %{
        "email" => email,
        "api_key" => credential.api_key,
        "signature" => signature,
        "timestamp" => timestamp
      })

    %{user_id: user.id, socket: socket}
  end

  test "a context create_document is pushed to a joined user channel", %{user_id: user_id} do
    doc_id = Ecto.UUID.generate()

    {:ok, doc} =
      Documents.create_document(user_id, %{
        "id" => doc_id,
        "content" => %{"type" => "tuningSet", "title" => "New Set"}
      })

    assert_push "document_created", payload
    assert payload.id == doc.id
    assert payload.content == %{"type" => "tuningSet", "title" => "New Set"}
    assert payload.sync_revision == doc.sync_revision
    assert payload.user_id == user_id
  end

  test "a context delete_document is pushed to a joined user channel", %{user_id: user_id} do
    {:ok, doc} =
      Documents.create_document(user_id, %{
        "id" => Ecto.UUID.generate(),
        "content" => %{"title" => "Doomed"}
      })

    {:ok, _deleted} = Documents.delete_document(user_id, doc.id)

    assert_push "document_deleted", payload
    assert payload.id == doc.id
  end

  test "a context replace_content is pushed to a joined user channel", %{user_id: user_id} do
    {:ok, doc} =
      Documents.create_document(user_id, %{
        "id" => Ecto.UUID.generate(),
        "content" => %{"title" => "Original"}
      })

    {:ok, _updated} = Documents.replace_content(doc, %{"title" => "Renamed from web"})

    assert_push "document_updated", payload
    assert payload.id == doc.id
    assert is_list(payload.patch)
  end
end
