defmodule Mix.Tasks.Replicant.Gen.Credentials do
  @moduledoc """
  Generates API credentials for application authentication.

  ## Usage

      mix replicant.gen.credentials --name "My Application"

  This will create a new API credential pair and print it to stdout.
  The secret is only shown once - store it securely.
  """

  use Mix.Task

  @shortdoc "Generate API credentials"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [name: :string])

    name = opts[:name] || raise "Missing required --name option"

    Mix.Task.run("app.start")

    case ReplicantServer.Auth.create_credential(name) do
      {:ok, credential} ->
        Mix.shell().info("""

        API Credentials Generated
        =========================
        Name:    #{credential.name}
        API Key: #{credential.api_key}
        Secret:  #{credential.secret}

        ⚠️  Store the secret securely - it cannot be retrieved later.
        """)

      {:error, changeset} ->
        Mix.shell().error("Failed to create credential:")
        Mix.shell().error(inspect(changeset.errors))
    end
  end
end
