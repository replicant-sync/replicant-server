defmodule ReplicantServer.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :replicant_server

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def create_credentials(name) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(ReplicantServer.Repo, fn _repo ->
        case ReplicantServer.Auth.create_credential(name) do
          {:ok, credential} ->
            IO.puts("Credentials created for: #{name}")
            IO.puts("API Key:  #{credential.api_key}")
            IO.puts("Secret:   #{credential.secret}")
            IO.puts("")
            IO.puts("Save the secret now — it cannot be retrieved later.")

          {:error, changeset} ->
            IO.puts("Error: #{inspect(changeset.errors)}")
        end
      end)
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
