defmodule ReplicantServer.Sync.Channel do
  @moduledoc """
  Phoenix Channel for real-time document synchronization.

  Handles: create, update, delete, full sync, and change polling.
  """
  use Phoenix.Channel

  alias ReplicantServer.{Auth, Documents}
  alias ReplicantServer.OT.Transform

  require Logger

  @impl true
  def join("sync:" <> _rest = topic, params, socket) do
    with {:ok, email} <- Map.fetch(params, "email"),
         {:ok, api_key} <- Map.fetch(params, "api_key"),
         {:ok, signature} <- Map.fetch(params, "signature"),
         {:ok, timestamp} <- Map.fetch(params, "timestamp"),
         {:ok, credential} <- Auth.verify_hmac(api_key, signature, timestamp, email),
         :ok <- require_enrolled(credential.user_id),
         :ok <- validate_topic(topic, credential.user_id) do
      socket = assign(socket, :user_id, credential.user_id)

      Logger.info("Credential #{credential.id} joined #{topic}")
      {:ok, %{user_id: credential.user_id}, socket}
    else
      :error ->
        {:error, %{reason: "missing_params"}}

      {:error, reason} ->
        Logger.warning("Join rejected: #{inspect(reason)}")
        {:error, %{reason: to_string(reason)}}
    end
  end

  # Identity comes from the authenticated credential's user_id. A credential
  # with no user_id (the retired shared secret) cannot resolve identity and is
  # refused before any topic check — otherwise a nil user_id reaches document
  # queries and raises on `where user_id == ^nil`.
  defp require_enrolled(nil), do: {:error, :credential_not_enrolled}
  defp require_enrolled(_user_id), do: :ok

  defp validate_topic("sync:user:" <> topic_id, user_id) do
    if topic_id == user_id, do: :ok, else: {:error, :topic_user_mismatch}
  end

  defp validate_topic("sync:public", _user_id), do: :ok
  defp validate_topic(_topic, _user_id), do: {:error, :invalid_topic}

  # ============================================================================
  # Create Document
  # ============================================================================

  # Documents.create_document broadcasts "document_created" to sync:user
  # itself (excluding this channel's own pid via :broadcast_from), so no
  # separate broadcast_except call is needed here.
  @impl true
  def handle_in("create_document", payload, socket) do
    user_id = socket.assigns.user_id
    payload = Map.drop(payload, ["author_name", "visibility", "provenance", "user_id"])

    case Documents.create_document(user_id, payload, broadcast_from: self()) do
      {:ok, document} ->
        payload =
          %{
            id: document.id,
            content: document.content,
            sync_revision: document.sync_revision,
            content_hash: document.content_hash
          }
          |> Map.merge(Documents.envelope_fields(document))

        maybe_broadcast_public(socket, document, "document_created", payload)

        {:reply,
         {:ok,
          %{
            id: document.id,
            sync_revision: document.sync_revision,
            content_hash: document.content_hash
          }
          |> Map.merge(Documents.envelope_fields(document))}, socket}

      {:error, :conflict, existing} ->
        {:reply,
         {:error,
          %{
            reason: "conflict",
            existing_id: existing.id,
            sync_revision: existing.sync_revision
          }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # ============================================================================
  # Update Document
  # ============================================================================

  # Documents.update_document broadcasts "document_updated" to sync:user (and
  # sync:public, when public) itself, excluding this channel's own pid via
  # :broadcast_from — no separate broadcast_except/maybe_broadcast_public
  # call is needed here.
  @impl true
  def handle_in("update_document", payload, socket) do
    user_id = socket.assigns.user_id
    document_id = payload["id"]
    patch = payload["patch"]
    content_hash = payload["content_hash"]

    case Documents.update_document(user_id, document_id, patch, content_hash,
           broadcast_from: self()
         ) do
      {:ok, document} ->
        {:reply, {:ok, %{sync_revision: document.sync_revision}}, socket}

      {:error, :hash_mismatch, current} ->
        {:reply,
         {:error,
          %{
            reason: "hash_mismatch",
            current_revision: current.sync_revision,
            current_content: current.content,
            current_hash: current.content_hash
          }}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, :missing_hash} ->
        {:reply, {:error, %{reason: "missing_hash"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # ============================================================================
  # Delete Document
  # ============================================================================

  # Documents.delete_document broadcasts "document_deleted" to sync:user (and
  # sync:public, when public) itself, excluding this channel's own pid via
  # :broadcast_from — no separate broadcast_except/maybe_broadcast_public
  # call is needed here.
  @impl true
  def handle_in("delete_document", payload, socket) do
    user_id = socket.assigns.user_id
    document_id = payload["id"]

    case Documents.delete_document(user_id, document_id, broadcast_from: self()) do
      {:ok, _document} ->
        {:reply, :ok, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # ============================================================================
  # Full Sync (get all documents)
  # ============================================================================

  @impl true
  def handle_in("request_full_sync", _payload, socket) do
    user_id = socket.assigns.user_id

    user_documents = Documents.list_user_documents(user_id)
    public_documents = Documents.list_public_documents()
    documents = user_documents ++ public_documents
    latest_sequence = Documents.get_latest_sequence(user_id)

    doc_list =
      Enum.map(documents, fn doc ->
        %{
          id: doc.id,
          user_id: doc.user_id,
          content: doc.content,
          sync_revision: doc.sync_revision,
          content_hash: doc.content_hash,
          created_at: doc.created_at,
          updated_at: doc.updated_at
        }
        |> Map.merge(Documents.envelope_fields(doc))
      end)

    {:reply, {:ok, %{documents: doc_list, latest_sequence: latest_sequence}}, socket}
  end

  # ============================================================================
  # Get Document (targeted resync)
  # ============================================================================

  @impl true
  def handle_in("get_document", %{"id" => document_id}, socket) do
    user_id = socket.assigns.user_id

    document =
      Documents.get_user_document_any(user_id, document_id) ||
        Documents.get_public_document_any(document_id)

    case document do
      nil ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      document ->
        {:reply,
         {:ok,
          %{
            id: document.id,
            content: document.content,
            sync_revision: document.sync_revision,
            content_hash: document.content_hash,
            deleted: document.deleted_at != nil
          }}, socket}
    end
  end

  # ============================================================================
  # Get Changes Since (incremental sync)
  # ============================================================================

  @impl true
  def handle_in("get_changes_since", payload, socket) do
    user_id = socket.assigns.user_id
    last_sequence = payload["last_sequence"] || 0

    events = Documents.get_changes_since(user_id, last_sequence)
    latest_sequence = Documents.get_latest_sequence(user_id)

    event_list =
      Enum.map(events, fn event ->
        %{
          sequence: event.sequence,
          id: event.document_id,
          event_type: event.event_type,
          forward_patch: event.forward_patch,
          reverse_patch: event.reverse_patch,
          server_timestamp: event.server_timestamp
        }
        |> Map.merge(
          case event.document do
            %Documents.Document{} = doc -> Documents.envelope_fields(doc) |> Map.delete(:user_id)
            _ -> %{}
          end
        )
      end)

    {:reply, {:ok, %{events: event_list, latest_sequence: latest_sequence}}, socket}
  end

  # ============================================================================
  # Transform Operations (for conflict resolution)
  # ============================================================================

  @impl true
  def handle_in("transform_operations", payload, socket) do
    local_ops = payload["local_ops"] || []
    remote_ops = payload["remote_ops"] || []

    case Transform.transform_patches(local_ops, remote_ops) do
      {:ok, {transformed_local, transformed_remote}} ->
        {:reply,
         {:ok, %{transformed_local: transformed_local, transformed_remote: transformed_remote}},
         socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # Context-originated broadcasts (a host app writing through Documents) are
  # delivered to the channel process rather than the transport fastlane, and
  # Phoenix hands them to handle_out/3 — forward them to the client unchanged.
  @impl true
  def handle_out(event, payload, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Publicly visible documents fan out to the sync:public topic in addition
  # to the owner's topic, so public-catalog subscribers stay current.
  defp maybe_broadcast_public(socket, document, event, payload) do
    if document.visibility == "public" do
      socket.endpoint.broadcast("sync:public", event, payload)
    end
  end
end
