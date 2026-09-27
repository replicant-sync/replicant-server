defmodule ReplicantServer.Sync.Channel do
  @moduledoc "Protocol v2 sync channel: one per connection, topic `sync:v2`."

  use Phoenix.Channel

  alias ReplicantServer.{Auth, Feed, Publications, Scopes}
  alias ReplicantServer.Sync.{Envelope, Protocol, Upload}

  require Logger

  @protocol_version 2

  @impl true
  def join("sync:v2", params, socket) do
    case authenticate(params) do
      {:ok, user_id} ->
        {:ok, %{user_id: user_id, protocol_version: @protocol_version},
         assign(socket, user_id: user_id, scopes: MapSet.new())}

      {:error, code} ->
        Logger.warning("Join rejected: #{code}")
        {:error, Envelope.error(code)}
    end
  end

  @impl true
  def handle_in("get_changes_since", params, socket) do
    with_scope(params, socket, &Protocol.changes_since(&1, &2, params))
  end

  def handle_in("get_snapshot", params, socket) do
    with_scope(params, socket, &Protocol.snapshot(&1, &2, params))
  end

  def handle_in("upload", params, socket) do
    {:reply, Upload.run(socket.assigns.user_id, socket.assigns.client_id, params), socket}
  end

  def handle_in("get_document", params, socket) do
    {:reply, Protocol.get_document(socket.assigns.user_id, params), socket}
  end

  def handle_in("publish", %{"source_doc_id" => id}, socket) when is_binary(id) do
    {:reply, Protocol.publication_reply(Publications.publish(socket.assigns.user_id, id)), socket}
  end

  def handle_in("publish_update", %{"publication_id" => id}, socket) when is_binary(id) do
    {:reply, Protocol.publication_reply(Publications.publish_update(socket.assigns.user_id, id)),
     socket}
  end

  def handle_in("unpublish", %{"publication_id" => id}, socket) when is_binary(id) do
    {:reply, Protocol.publication_reply(Publications.unpublish(socket.assigns.user_id, id)),
     socket}
  end

  def handle_in(_event, _params, socket) do
    {:reply, {:error, Envelope.error("validation")}, socket}
  end

  @impl true
  def handle_info({:feed_change, event, doc}, socket) do
    push(socket, "change", Envelope.change(event, doc, Scopes.to_wire(event.scope)))
    {:noreply, socket}
  end

  # Subscribes before the handler reads, so a change committed after the read
  # arrives as a push and none falls between.
  defp with_scope(%{"scope" => wire_scope}, socket, handler) when is_binary(wire_scope) do
    case Scopes.resolve(wire_scope, socket.assigns.user_id) do
      {:ok, scope_key} ->
        socket = subscribe_scope(socket, scope_key)
        {:reply, handler.(scope_key, wire_scope), socket}

      {:error, :subscription_forbidden} ->
        {:reply, {:error, Envelope.error("subscription_forbidden", %{scope: wire_scope})}, socket}
    end
  end

  defp with_scope(_params, socket, _handler) do
    {:reply, {:error, Envelope.error("validation")}, socket}
  end

  defp subscribe_scope(socket, scope_key) do
    if MapSet.member?(socket.assigns.scopes, scope_key) do
      socket
    else
      :ok = Phoenix.PubSub.subscribe(ReplicantServer.PubSub, Feed.topic(scope_key))
      assign(socket, :scopes, MapSet.put(socket.assigns.scopes, scope_key))
    end
  end

  defp authenticate(%{
         "email" => email,
         "api_key" => api_key,
         "signature" => signature,
         "timestamp" => timestamp
       })
       when is_binary(email) and is_binary(api_key) and is_binary(signature) and
              is_integer(timestamp) do
    case Auth.verify_hmac(api_key, signature, timestamp, email) do
      {:ok, %{user_id: nil}} -> {:error, "auth_invalid"}
      {:ok, %{user_id: user_id}} -> {:ok, user_id}
      {:error, :timestamp_expired} -> {:error, "clock_skew"}
      {:error, _reason} -> {:error, "auth_invalid"}
    end
  end

  defp authenticate(_params), do: {:error, "auth_invalid"}
end
