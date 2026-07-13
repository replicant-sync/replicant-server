{:ok, _} = ReplicantServer.Sync.TestEndpoint.start_link()
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ReplicantServer.Repo, :manual)
