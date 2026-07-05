defmodule ReplicantServer.Sync.TestEndpoint do
  @moduledoc """
  Minimal endpoint for exercising the sync socket in channel tests.
  Production apps mount `ReplicantServer.Sync.Socket` in their own endpoint.
  """

  use Phoenix.Endpoint, otp_app: :replicant_server

  socket "/socket", ReplicantServer.Sync.Socket,
    websocket: [check_origin: false],
    longpoll: false
end
