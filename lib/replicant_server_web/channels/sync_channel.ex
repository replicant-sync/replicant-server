defmodule ReplicantServerWeb.SyncChannel do
  @moduledoc """
  Phoenix Channel for real-time document synchronization.

  Handles: create, update, delete, full sync, and change polling.
  """
  use Phoenix.Channel

  alias ReplicantServer.{Auth, Accounts, Documents}
  alias ReplicantServer.OT.Transform

  require Logger

  @impl true
  def join("sync:" <> _topic, params, socket) do
    with {:ok, email} <- Map.fetch(params, "email"),
         {:ok, api_key} <- Map.fetch(params, "api_key"),
         {:ok, signature} <- Map.fetch(params, "signature"),
         {:ok, timestamp} <- Map.fetch(params, "timestamp"),
         {:ok, _credential} <- Auth.verify_hmac(api_key, signature, timestamp, email),
         {:ok, user} <- Accounts.get_or_create_user(email) do
      socket =
        socket
        |> assign(:user_id, user.id)
        |> assign(:email, email)

      Logger.info("User #{email} joined sync channel")
      {:ok, %{user_id: user.id}, socket}
    else
      :error ->
        {:error, %{reason: "missing_params"}}

      {:error, reason} ->
        Logger.warning("Auth failed: #{inspect(reason)}")
        {:error, %{reason: to_string(reason)}}
    end
  end

  # ============================================================================
  # Create Document
  # ============================================================================

  @impl true
  def handle_in("create_document", payload, socket) do
    user_id = socket.assigns.user_id

    case Documents.create_document(user_id, payload) do
      {:ok, document} ->
        broadcast_except(socket, "document_created", %{
          document_id: document.id,
          content: document.content,
          sync_revision: document.sync_revision,
          content_hash: document.content_hash
        })

        {:reply, {:ok, %{document_id: document.id, sync_revision: document.sync_revision, content_hash: document.content_hash}},
         socket}

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

  @impl true
  def handle_in("update_document", payload, socket) do
    user_id = socket.assigns.user_id
    document_id = payload["document_id"]
    patch = payload["patch"]
    content_hash = payload["content_hash"]

    case Documents.update_document(user_id, document_id, patch, content_hash) do
      {:ok, document} ->
        broadcast_except(socket, "document_updated", %{
          document_id: document.id,
          patch: patch,
          sync_revision: document.sync_revision,
          content_hash: document.content_hash
        })

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

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # ============================================================================
  # Delete Document
  # ============================================================================

  @impl true
  def handle_in("delete_document", payload, socket) do
    user_id = socket.assigns.user_id
    document_id = payload["document_id"]

    case Documents.delete_document(user_id, document_id) do
      {:ok, _document} ->
        broadcast_except(socket, "document_deleted", %{
          document_id: document_id
        })

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

    documents = Documents.list_user_documents(user_id)
    latest_sequence = Documents.get_latest_sequence(user_id)

    doc_list =
      Enum.map(documents, fn doc ->
        %{
          id: doc.id,
          content: doc.content,
          sync_revision: doc.sync_revision,
          content_hash: doc.content_hash,
          created_at: doc.created_at,
          updated_at: doc.updated_at
        }
      end)

    {:reply, {:ok, %{documents: doc_list, latest_sequence: latest_sequence}}, socket}
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
          document_id: event.document_id,
          event_type: event.event_type,
          forward_patch: event.forward_patch,
          reverse_patch: event.reverse_patch,
          server_timestamp: event.server_timestamp
        }
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

  # ============================================================================
  # Helpers
  # ============================================================================

  defp broadcast_except(socket, event, payload) do
    broadcast_from!(socket, event, payload)
  end
end
