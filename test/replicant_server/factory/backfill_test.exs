defmodule ReplicantServer.Factory.BackfillTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Accounts
  alias ReplicantServer.Collections.CollectionMember
  alias ReplicantServer.Documents
  alias ReplicantServer.Factory.Backfill
  alias ReplicantServer.Feed.ChangeEvent

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
    assert partch.author_id == robert_rich.id
    assert partch.author_name == "Robert Rich"
    assert partch.read_only
    assert is_nil(partch.user_id)

    hexany = by_title["7-limit Hexany"]
    assert hexany.author_id == sevish.id
    assert hexany.author_name == "Sevish"

    tet = by_title["12-TET"]
    assert tet.author_id == entonal.id
    assert tet.author_name == "Entonal"

    assert Enum.all?(pubs, &Repo.get_by(CollectionMember, document_id: &1.id))
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

  test "author-only change on re-run writes one upsert event with the new author, content unchanged",
       %{dir: dir} do
    assert {:ok, _} = Backfill.run(dir, @config)

    hexany_before =
      Documents.list_public_documents() |> Enum.find(&(&1.content["title"] == "7-limit Hexany"))

    events_before = events_for(hexany_before.id)

    config2 = %{
      @config
      | contributors:
          Map.put(@config.contributors, "Wendy Carlos", %{
            email: "wendy@example.com",
            display_name: "Wendy Carlos"
          }),
        overrides: %{"7-limit-hexany" => "Wendy Carlos"}
    }

    assert {:ok, %{created: 0, updated: 3}} = Backfill.run(dir, config2)

    wendy = Accounts.get_user_by_email("wendy@example.com")
    hexany_after = Documents.get_document(hexany_before.id)

    assert hexany_after.author_id == wendy.id
    assert hexany_after.author_name == "Wendy Carlos"
    assert hexany_after.content == hexany_before.content

    new_events = events_for(hexany_after.id) -- events_before
    assert [%{scope: "collection:curated", kind: "upsert", seq: seq}] = new_events
    assert seq == hexany_after.seq
  end

  test "fully unchanged re-run writes no new events or membership rows", %{dir: dir} do
    assert {:ok, _} = Backfill.run(dir, @config)
    events_before = Repo.aggregate(ChangeEvent, :count)
    members_before = Repo.aggregate(CollectionMember, :count)

    assert {:ok, %{created: 0, updated: 3}} = Backfill.run(dir, @config)

    assert Repo.aggregate(ChangeEvent, :count) == events_before
    assert Repo.aggregate(CollectionMember, :count) == members_before
  end

  defp events_for(doc_id),
    do: Repo.all(from e in ChangeEvent, where: e.doc_id == ^doc_id, order_by: e.seq)

  test "deterministic_doc_id reproduces the historical per-slug derivation" do
    expected =
      UUID.uuid5(
        UUID.uuid5(:dns, "com.nodeaudio.entonal"),
        "com.nodeaudio.entonal/factory-tuning/some-slug"
      )

    assert ReplicantServer.Factory.Backfill.deterministic_doc_id("Some-Slug") == expected
  end
end
