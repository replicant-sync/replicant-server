defmodule ReplicantServer.JsonPatchFixtureTest do
  use ExUnit.Case, async: true

  alias ReplicantServer.Documents

  # Recorded by the Rust client from json_patch::diff; the same file is checked there.
  @fixture Path.expand("../fixtures/json_patch_fixture.json", __DIR__)

  test "every client patch applies to the same result" do
    mismatches =
      for c <- @fixture |> File.read!() |> Jason.decode!(),
          Documents.apply_patch(c["patch"], c["doc"]) != {:ok, c["result"]},
          do: c["name"]

    assert mismatches == []
  end
end
