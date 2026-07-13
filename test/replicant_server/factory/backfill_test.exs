defmodule ReplicantServer.Factory.BackfillTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Accounts
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

    File.write!(
      Path.join(dir, "partch-43-tone.json"),
      ~s({"type":"tuning","title":"Partch 43-tone","author":"Robert Rich","pitches":["1","2"]})
    )

    File.write!(
      Path.join(dir, "7-limit-hexany.json"),
      ~s({"type":"tuning","title":"7-limit Hexany","author":"","pitches":["1"]})
    )

    File.write!(
      Path.join(dir, "12-tone-equal-temperament.json"),
      ~s({"type":"tuning","title":"12-TET","author":"","pitches":["1"]})
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "backfill mints owners and attributes each preset", %{dir: dir} do
    assert {:ok, %{created: 3, updated: 0, users: 3}} = Backfill.run(dir, @config)

    pubs = Documents.list_public_documents()
    by_title = Map.new(pubs, &{&1.content["title"], &1})

    robert_rich = Accounts.get_user_by_email("rr@robertrich.com")
    sevish = Accounts.get_user_by_email("sean@sevish.com")
    entonal = Accounts.get_user_by_email("factory@nodeaudio.com")

    partch = by_title["Partch 43-tone"]
    assert partch.user_id == robert_rich.id
    assert partch.author_name == "Robert Rich"
    assert partch.visibility == "public"

    hexany = by_title["7-limit Hexany"]
    assert hexany.user_id == sevish.id
    assert hexany.author_name == "Sevish"

    tet = by_title["12-TET"]
    assert tet.user_id == entonal.id
    assert tet.author_name == "Entonal"
  end

  test "backfill raises a clear error when an override names an unknown contributor", %{dir: dir} do
    config = %{@config | overrides: %{"7-limit-hexany" => "Typo Name"}}

    assert_raise ArgumentError, ~r/unknown contributor "Typo Name".+7-limit-hexany/, fn ->
      Backfill.run(dir, config)
    end
  end

  test "backfill is idempotent — a second run updates, does not duplicate", %{dir: dir} do
    assert {:ok, %{created: 3}} = Backfill.run(dir, @config)
    assert {:ok, %{created: 0, updated: 3}} = Backfill.run(dir, @config)
    assert length(Documents.list_public_documents()) == 3
  end

  test "deterministic_doc_id reproduces the historical per-slug derivation" do
    expected =
      UUID.uuid5(
        UUID.uuid5(:dns, "com.nodeaudio.entonal"),
        "com.nodeaudio.entonal/factory-tuning/some-slug"
      )

    assert ReplicantServer.Factory.Backfill.deterministic_doc_id("Some-Slug") == expected
  end
end
