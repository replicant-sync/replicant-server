defmodule ReplicantServer.BoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The sync library must not reference any web application module.
  """

  @library_dirs ["lib", "test"]
  @self "test/replicant_server/boundary_test.exs"
  @forbidden "ReplicantServer" <> "Web"

  test "no module references the web application" do
    violations =
      @library_dirs
      |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.{ex,exs}"))
      |> Kernel.--([@self])
      |> Enum.filter(&(File.read!(&1) =~ @forbidden))

    assert violations == [],
           "files reference #{@forbidden}: #{inspect(violations)}"
  end
end
