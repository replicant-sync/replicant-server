defmodule ReplicantServer.BoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Enforces the library/web boundary documented in CLAUDE.md: library
  modules must not reference the web application. `application.ex` is
  the composition root and is exempt until the web app is extracted.
  """

  @library_dirs ["lib/replicant_server", "lib/mix"]
  @exempt ["lib/replicant_server/application.ex"]

  test "library modules do not reference ReplicantServerWeb" do
    violations =
      @library_dirs
      |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.ex"))
      |> Kernel.--(@exempt)
      |> Enum.filter(&(File.read!(&1) =~ "ReplicantServerWeb"))

    assert violations == [],
           "library files reference ReplicantServerWeb: #{inspect(violations)}"
  end
end
