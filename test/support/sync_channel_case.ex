defmodule ReplicantServer.Sync.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by sync channel tests.

  The endpoint hosting the sync socket is injected via the
  `:sync_test_endpoint` config so the library test suite carries no
  compile-time reference to the web application.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import ReplicantServer.Sync.ChannelCase

      @endpoint Application.compile_env!(:replicant_server, :sync_test_endpoint)
    end
  end

  setup tags do
    ReplicantServer.DataCase.setup_sandbox(tags)
    :ok
  end
end
