defmodule ReplicantServer.Sync.Channel do
  @moduledoc """
  Phoenix Channel for real-time document synchronization.

  Handles: create, update, delete, full sync, and change polling.
  """
  use Phoenix.Channel

  alias ReplicantServer.{Auth, Accounts, Documents}
  alias ReplicantServer.OT.Transform

  require Logger

  @impl true
  def join("sync:" <> _rest = topic, params, socket) do
    with {:ok, email} <- Map.fetch(params, "email"),
         {:ok, api_key} <- Map.fetch(params, "api_key"),
         {:ok, signature} <- Map.fetch(params, "signature"),
         {:ok, timestamp} <- Map.fetch(params, "timestamp"),
         {:ok, _credential} <- Auth.verify_hmac(api_key, signature, timestamp, email),
         {:ok, user, mode} <- resolve_user(params, email),
         :ok <- validate_topic(topic, user, mode) do
      socket =
        socket
        |> assign(:user_id, user.id)
        |> assign(:email, user.email)

      Logger.info("User #{user.email} joined sync channel")
      {:ok, %{user_id: user.id, email: user.email}, socket}
    else
      :error ->
        {:error, %{reason: "missing_params"}}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("User resolution failed on join: #{inspect(changeset.errors)}")
        {:error, %{reason: "user_resolution_failed"}}

      {:error, reason} ->
        Logger.warning("Join rejected: #{inspect(reason)}")
        {:error, %{reason: to_string(reason)}}
    end
  end

  # A payload user_id (steady-state join) wins; an unknown or absent one falls
  # back to email resolution (bootstrap join, or self-healing after the server
  # database was reset).
  defp resolve_user(%{"user_id" => user_id}, email) when is_binary(user_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(user_id),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      {:ok, user, :by_id}
    else
      _ -> bootstrap_resolve(email)
    end
  end

  defp resolve_user(_params, email), do: bootstrap_resolve(email)

  defp bootstrap_resolve(email) do
    case Accounts.get_or_create_user(email) do
      {:ok, user} -> {:ok, user, :bootstrap}
      error -> error
    end
  end

  # A steady-state join must sit on its own topic. A bootstrap join may sit on
  # a provisional topic: the client adopts the returned canonical id, then
  # rejoins the canonical topic.
  defp validate_topic("sync:user:" <> topic_id, user, :by_id) do
    if topic_id == user.id, do: :ok, else: {:error, :topic_user_mismatch}
  end

  defp validate_topic(_topic, _user, _mode), do: :ok

  # ============================================================================
  # Create Document
  # ============================================================================

  @impl true
  def handle_in("create_document", payload, socket) do
    user_id = socket.assigns.user_id
    payload = Map.drop(payload, ["author_name", "visibility", "provenance", "user_id"])

    case Documents.create_document(user_id, payload) do
      {:ok, document} ->
        payload =
          %{
            id: document.id,
            content: document.content,
            sync_revision: document.sync_revision,
            content_hash: document.content_hash
          }
          |> Map.merge(Documents.envelope_fields(document))

        broadcast_except(socket, "document_created", payload)
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

  @impl true
  def handle_in("update_document", payload, socket) do
    user_id = socket.assigns.user_id
    document_id = payload["id"]
    patch = payload["patch"]
    content_hash = payload["content_hash"]

    case Documents.update_document(user_id, document_id, patch, content_hash) do
      {:ok, document} ->
        update_payload = %{
          id: document.id,
          patch: patch,
          sync_revision: document.sync_revision,
          content_hash: document.content_hash
        }

        broadcast_except(socket, "document_updated", update_payload)
        maybe_broadcast_public(socket, document, "document_updated", update_payload)

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
    document_id = payload["id"]

    case Documents.delete_document(user_id, document_id) do
      {:ok, document} ->
        delete_payload = %{id: document_id}

        broadcast_except(socket, "document_deleted", delete_payload)
        maybe_broadcast_public(socket, document, "document_deleted", delete_payload)

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

  # ============================================================================
  # Helpers
  # ============================================================================

  defp broadcast_except(socket, event, payload) do
    broadcast_from!(socket, event, payload)
  end

  # Publicly visible documents fan out to the sync:public topic in addition
  # to the owner's topic, so public-catalog subscribers stay current.
  defp maybe_broadcast_public(socket, document, event, payload) do
    if document.visibility == "public" do
      socket.endpoint.broadcast("sync:public", event, payload)
    end
  end
end
