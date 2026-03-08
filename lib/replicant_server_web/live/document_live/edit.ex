defmodule ReplicantServerWeb.DocumentLive.Edit do
  use ReplicantServerWeb, :live_view

  alias ReplicantServer.Documents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, json_error: nil, conflict_warning: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Document")
    |> assign(:document, nil)
    |> assign(:is_public, false)
    |> assign(:content_text, "{\n  \n}")
  end

  defp apply_action(socket, :new_public, _params) do
    socket
    |> assign(:page_title, "New Public Document")
    |> assign(:document, nil)
    |> assign(:is_public, true)
    |> assign(:content_text, "{\n  \n}")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    document = Documents.get_user_document(socket.assigns.current_user.id, id)
    setup_edit(socket, document, false)
  end

  defp apply_action(socket, :edit_public, %{"id" => id}) do
    document = Documents.get_public_document(id)
    setup_edit(socket, document, true)
  end

  defp setup_edit(socket, nil, is_public) do
    socket
    |> put_flash(:error, "Document not found")
    |> redirect(to: if(is_public, do: ~p"/public", else: ~p"/documents"))
  end

  defp setup_edit(socket, document, is_public) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ReplicantServer.PubSub, "documents:#{document.id}")
    end

    socket
    |> assign(:page_title, "Edit Document")
    |> assign(:document, document)
    |> assign(:is_public, is_public)
    |> assign(:content_text, Jason.encode!(document.content, pretty: true))
  end

  @impl true
  def handle_event("save", %{"content" => content_text}, socket) do
    case Jason.decode(content_text) do
      {:ok, content} when is_map(content) ->
        save_document(socket, content)

      {:ok, _} ->
        {:noreply, assign(socket, :json_error, "Content must be a JSON object")}

      {:error, %Jason.DecodeError{} = err} ->
        {:noreply, assign(socket, :json_error, "Invalid JSON: #{Exception.message(err)}")}
    end
  end

  defp save_document(socket, content) do
    case {socket.assigns.document, socket.assigns.is_public} do
      {nil, false} ->
        create_user_document(socket, content)

      {nil, true} ->
        create_public_document(socket, content)

      {document, _} ->
        update_existing(socket, document, content)
    end
  end

  defp create_user_document(socket, content) do
    user_id = socket.assigns.current_user.id
    attrs = %{id: Ecto.UUID.generate(), content: content}

    case Documents.create_document(user_id, attrs) do
      {:ok, doc} ->
        {:noreply,
         socket
         |> put_flash(:info, "Document created")
         |> redirect(to: ~p"/documents/#{doc.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create document")}
    end
  end

  defp create_public_document(socket, content) do
    case Documents.create_public_document(%{content: content}) do
      {:ok, doc} ->
        {:noreply,
         socket
         |> put_flash(:info, "Public document created")
         |> redirect(to: ~p"/public/#{doc.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create document")}
    end
  end

  defp update_existing(socket, document, content) do
    case Documents.replace_content(document, content) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:document, updated)
         |> assign(:json_error, nil)
         |> assign(:conflict_warning, nil)
         |> put_flash(:info, "Document saved")}

      {:error, :invalid_patch} ->
        {:noreply, put_flash(socket, :error, "Failed to compute diff")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save")}
    end
  end

  @impl true
  def handle_info({:document_updated, doc}, socket) do
    if socket.assigns.document && doc.id == socket.assigns.document.id do
      {:noreply,
       socket
       |> assign(:document, doc)
       |> assign(:conflict_warning, "This document was modified by another client. Your textarea may be stale.")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:document_deleted, _doc}, socket) do
    is_public = socket.assigns.is_public

    {:noreply,
     socket
     |> put_flash(:error, "Document was deleted")
     |> redirect(to: if(is_public, do: ~p"/public", else: ~p"/documents"))}
  end
end
