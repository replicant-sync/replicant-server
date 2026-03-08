defmodule ReplicantServerWeb.DocumentLive.Index do
  use ReplicantServerWeb, :live_view

  alias ReplicantServer.Documents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ReplicantServer.PubSub, "documents:user:#{user.id}")
    end

    documents = Documents.list_user_documents(user.id)
    {:ok, assign(socket, :documents, documents)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Documents.delete_document(socket.assigns.current_user.id, id) do
      {:ok, _} ->
        documents = Documents.list_user_documents(socket.assigns.current_user.id)
        {:noreply, socket |> put_flash(:info, "Document deleted") |> assign(:documents, documents)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete document")}
    end
  end

  @impl true
  def handle_info({event, _doc}, socket) when event in [:document_created, :document_updated, :document_deleted] do
    documents = Documents.list_user_documents(socket.assigns.current_user.id)
    {:noreply, assign(socket, :documents, documents)}
  end
end
