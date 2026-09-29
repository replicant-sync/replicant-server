defmodule ReplicantServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ReplicantServer.Repo,
        {Phoenix.PubSub, name: ReplicantServer.PubSub}
      ] ++ retention_children()

    opts = [strategy: :one_for_one, name: ReplicantServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp retention_children do
    if Application.get_env(:replicant_server, :retention, [])[:enabled] == false,
      do: [],
      else: [ReplicantServer.Feed.Retention]
  end
end
