defmodule ReplicantServerWeb.DocumentLive.Show do
  use ReplicantServerWeb, :live_view

  alias ReplicantServer.Documents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    is_public = socket.assigns.live_action == :show_public
    document = if is_public, do: Documents.get_public_document(id), else: Documents.get_user_document(socket.assigns.current_user.id, id)

    if document do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(ReplicantServer.PubSub, "documents:#{id}")
      end

      {:noreply,
       socket
       |> assign(:document, document)
       |> assign(:is_public, is_public)
       |> assign(:formatted_content, Jason.encode!(document.content, pretty: true))}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Document not found")
       |> redirect(to: if(is_public, do: ~p"/public", else: ~p"/documents"))}
    end
  end

  @impl true
  def handle_info({:document_updated, doc}, socket) do
    {:noreply,
     socket
     |> assign(:document, doc)
     |> assign(:formatted_content, Jason.encode!(doc.content, pretty: true))
     |> put_flash(:info, "Document updated by another client")}
  end

  def handle_info({:document_deleted, _doc}, socket) do
    is_public = socket.assigns.is_public

    {:noreply,
     socket
     |> put_flash(:error, "Document was deleted")
     |> redirect(to: if(is_public, do: ~p"/public", else: ~p"/documents"))}
  end
end
