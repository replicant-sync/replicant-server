defmodule ReplicantServer.Sync.ChannelCase do
  @moduledoc """
  Test case for the v2 sync channel. The endpoint hosting the socket is
  injected via the `:sync_test_endpoint` config so the library test suite
  carries no compile-time reference to the web application.
  """

  use ExUnit.CaseTemplate

  alias ReplicantServer.{Accounts, Auth, Repo}
  alias ReplicantServer.Auth.ApiCredential

  using do
    quote do
      import Phoenix.ChannelTest
      import Phoenix.ConnTest, except: [connect: 2, connect: 3]
      import Plug.Conn
      import ReplicantServer.Sync.ChannelCase

      @endpoint Application.compile_env!(:replicant_server, :sync_test_endpoint)

      def join_sync(ctx, opts \\ []) do
        assigns = %{
          protocol_version: Keyword.get(opts, :protocol_version, 2),
          client_id: Keyword.get(opts, :client_id, Ecto.UUID.generate())
        }

        ReplicantServer.Sync.Socket
        |> socket(nil, assigns)
        |> subscribe_and_join(
          ReplicantServer.Sync.Channel,
          "sync:v2",
          Keyword.get_lazy(opts, :params, fn -> auth_params(ctx) end)
        )
      end
    end
  end

  setup tags do
    ReplicantServer.DataCase.setup_sandbox(tags)
    :ok
  end

  def mint_user(email) do
    {:ok, user} = Accounts.get_or_create_user(email)
    %{user: user, email: email, credential: insert_credential(user.id)}
  end

  def insert_credential(user_id) do
    %ApiCredential{}
    |> ApiCredential.changeset(
      Map.merge(Auth.generate_credentials(), %{name: "test-device", user_id: user_id})
    )
    |> Repo.insert!()
  end

  def auth_params(%{email: email, credential: c}, timestamp \\ System.system_time(:second)) do
    %{
      "email" => email,
      "api_key" => c.api_key,
      "timestamp" => timestamp,
      "signature" => Auth.create_signature(c.secret, timestamp, email, c.api_key)
    }
  end
end
