defmodule ReplicantServer.Factory.BackfillTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Documents
  alias ReplicantServer.Factory.Backfill

  @config %{
    contributors: %{
      "Robert Rich" => %{email: "rr@robertrich.com", display_name: "Robert Rich"},
      "Sevish" => %{email: "sean@sevish.com", display_name: "Sevish"}
    },
    system: %{email: "factory@nodeaudio.com", display_name: "Entonal"},
    overrides: %{"7-limit-hexany" => "Sevish"}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "factory_seed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "partch-43-tone.json"), ~s({"type":"tuning","title":"Partch 43-tone","author":"Robert Rich","pitches":["1","2"]}))
    File.write!(Path.join(dir, "7-limit-hexany.json"), ~s({"type":"tuning","title":"7-limit Hexany","author":"","pitches":["1"]}))
    File.write!(Path.join(dir, "12-tone-equal-temperament.json"), ~s({"type":"tuning","title":"12-TET","author":"","pitches":["1"]}))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "backfill mints owners and attributes each preset", %{dir: dir} do
    assert {:ok, %{created: 3, updated: 0, users: 3}} = Backfill.run(dir, @config)

    pubs = Documents.list_public_documents()
    by_title = Map.new(pubs, &{&1.content["title"], &1})

    partch = by_title["Partch 43-tone"]
    assert partch.user_id == "26e545b7-b039-5de9-8f38-f302fd9da444"
    assert partch.author_name == "Robert Rich"
    assert partch.visibility == "public"

    hexany = by_title["7-limit Hexany"]
    assert hexany.user_id == "38795f16-1bf4-5a61-bbd1-df366c140494"
    assert hexany.author_name == "Sevish"

    tet = by_title["12-TET"]
    assert tet.user_id == "07895606-f8f5-5407-80c8-525bb48539ef"
    assert tet.author_name == "Entonal"
  end

  test "backfill is idempotent — a second run updates, does not duplicate", %{dir: dir} do
    assert {:ok, %{created: 3}} = Backfill.run(dir, @config)
    assert {:ok, %{created: 0, updated: 3}} = Backfill.run(dir, @config)
    assert length(Documents.list_public_documents()) == 3
  end
end
