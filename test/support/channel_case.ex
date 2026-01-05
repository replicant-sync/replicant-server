defmodule ReplicantServerWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import ReplicantServerWeb.ChannelCase

      @endpoint ReplicantServerWeb.Endpoint
    end
  end

  setup tags do
    ReplicantServer.DataCase.setup_sandbox(tags)
    :ok
  end
end
