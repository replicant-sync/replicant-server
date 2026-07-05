defmodule ReplicantServer.Sync.Socket do
  use Phoenix.Socket

  channel "sync:*", ReplicantServer.Sync.Channel

  @impl true
  def connect(_params, socket, _connect_info) do
    # Authentication happens in channel join, not socket connect
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
