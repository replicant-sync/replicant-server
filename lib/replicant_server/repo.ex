defmodule ReplicantServer.Repo do
  use Ecto.Repo,
    otp_app: :replicant_server,
    adapter: Ecto.Adapters.Postgres
end
