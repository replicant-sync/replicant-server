defmodule ReplicantServerWeb.DocumentLive.Index do
  use ReplicantServerWeb, :live_view

  alias ReplicantServer.Documents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ReplicantServer.PubSub, "documents:user:#{user.id}")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sort_by = params["sort_by"] || "updated_at"
    sort_order = params["sort_order"] || "desc"
    search = params["search"] || ""
    filters = parse_filters(params)

    opts = [
      sort_by: sort_by,
      sort_order: sort_order,
      search: search,
      filters: filters_to_tuples(filters)
    ]

    documents = Documents.list_user_documents(socket.assigns.current_user.id, opts)

    {:noreply,
     assign(socket,
       documents: documents,
       sort_by: String.to_existing_atom(sort_by),
       sort_order: String.to_existing_atom(sort_order),
       search: search,
       filters: filters
     )}
  rescue
    ArgumentError ->
      {:noreply, push_patch(socket, to: ~p"/documents")}
  end

  @impl true
  def handle_event("search", %{"search" => term}, socket) do
    params = build_params(socket.assigns, search: term)
    {:noreply, push_patch(socket, to: ~p"/documents?#{params}")}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    current = Atom.to_string(socket.assigns.sort_by)
    order = if field == current and socket.assigns.sort_order == :asc, do: "desc", else: "asc"
    params = build_params(socket.assigns, sort_by: field, sort_order: order)
    {:noreply, push_patch(socket, to: ~p"/documents?#{params}")}
  end

  def handle_event("add-filter", _, socket) do
    filters = socket.assigns.filters ++ [%{key: "", value: ""}]
    params = build_params(socket.assigns, filters: filters)
    {:noreply, push_patch(socket, to: ~p"/documents?#{params}")}
  end

  def handle_event("update-filter", %{"index" => index, "fk" => key, "fv" => value}, socket) do
    index = String.to_integer(index)
    filters = List.replace_at(socket.assigns.filters, index, %{key: key, value: value})
    params = build_params(socket.assigns, filters: filters)
    {:noreply, push_patch(socket, to: ~p"/documents?#{params}")}
  end

  def handle_event("remove-filter", %{"index" => index}, socket) do
    index = String.to_integer(index)
    filters = List.delete_at(socket.assigns.filters, index)
    params = build_params(socket.assigns, filters: filters)
    {:noreply, push_patch(socket, to: ~p"/documents?#{params}")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Documents.delete_document(socket.assigns.current_user.id, id) do
      {:ok, _} ->
        opts = current_query_opts(socket)
        documents = Documents.list_user_documents(socket.assigns.current_user.id, opts)
        {:noreply, socket |> put_flash(:info, "Document deleted") |> assign(:documents, documents)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete document")}
    end
  end

  @impl true
  def handle_info({event, _doc}, socket) when event in [:document_created, :document_updated, :document_deleted] do
    opts = current_query_opts(socket)
    documents = Documents.list_user_documents(socket.assigns.current_user.id, opts)
    {:noreply, assign(socket, :documents, documents)}
  end

  defp current_query_opts(socket) do
    [
      sort_by: socket.assigns.sort_by,
      sort_order: socket.assigns.sort_order,
      search: socket.assigns.search,
      filters: filters_to_tuples(socket.assigns.filters)
    ]
  end

  defp parse_filters(%{"fk" => keys, "fv" => values}) when is_list(keys) and is_list(values) do
    Enum.zip(keys, values)
    |> Enum.map(fn {k, v} -> %{key: k, value: v} end)
  end

  defp parse_filters(_), do: []

  defp filters_to_tuples(filters) do
    Enum.map(filters, fn %{key: k, value: v} -> {k, v} end)
  end

  defp build_params(assigns, overrides) do
    search = Keyword.get(overrides, :search, assigns.search)
    sort_by = Keyword.get(overrides, :sort_by, Atom.to_string(assigns.sort_by))
    sort_order = Keyword.get(overrides, :sort_order, Atom.to_string(assigns.sort_order))
    filters = Keyword.get(overrides, :filters, assigns.filters)

    params = %{
      "sort_by" => sort_by,
      "sort_order" => sort_order
    }

    params = if search != "", do: Map.put(params, "search", search), else: params

    if filters != [] do
      keys = Enum.map(filters, & &1.key)
      values = Enum.map(filters, & &1.value)
      params |> Map.put("fk", keys) |> Map.put("fv", values)
    else
      params
    end
  end
end
