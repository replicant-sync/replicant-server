defmodule ReplicantServer.ContentHashFixtureTest do
  use ExUnit.Case, async: true

  alias ReplicantServer.Documents

  # The same file is checked by the Rust client's test suite.
  @fixture Path.expand("../fixtures/content_hash_fixture.json", __DIR__)

  test "every fixture case hashes to its pinned value" do
    mismatches =
      for c <- @fixture |> File.read!() |> Jason.decode!(),
          Documents.compute_hash(c["content"]) != c["hash"],
          do: c["name"]

    assert mismatches == []
  end
end
