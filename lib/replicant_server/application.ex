defmodule ReplicantServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ReplicantServer.Repo,
      {Phoenix.PubSub, name: ReplicantServer.PubSub}
    ]

    opts = [strategy: :one_for_one, name: ReplicantServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
