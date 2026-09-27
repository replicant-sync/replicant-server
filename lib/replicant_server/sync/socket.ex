defmodule ReplicantServer.Sync.Socket do
  @moduledoc "Protocol v2 sync socket: version-checked at connect, one channel topic (`sync:v2`)."

  use Phoenix.Socket

  alias ReplicantServer.Sync.Envelope

  channel "sync:v2", ReplicantServer.Sync.Channel

  @protocol_version 2

  @impl true
  def connect(%{"protocol_version" => version} = params, socket, _connect_info) do
    case parse_version(version) do
      @protocol_version ->
        {:ok,
         assign(socket,
           protocol_version: @protocol_version,
           client_id: cast_uuid(params["client_id"])
         )}

      _other ->
        {:error, :update_required}
    end
  end

  def connect(_params, _socket, _connect_info), do: {:error, :update_required}

  @impl true
  def id(_socket), do: nil

  @doc "Websocket transport `error_handler` for a refused connect: replies HTTP 426."
  def handle_error(conn, :update_required) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(426, Jason.encode!(Envelope.error("update_required")))
  end

  defp parse_version(version) when is_integer(version), do: version

  defp parse_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_version(_), do: nil

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end
end
