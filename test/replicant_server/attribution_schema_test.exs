defmodule ReplicantServer.AttributionSchemaTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Accounts
  alias ReplicantServer.Accounts.User
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Repo

  test "user changeset accepts display_name" do
    cs =
      User.changeset(%User{}, %{
        id: Ecto.UUID.generate(),
        email: "x@example.com",
        display_name: "Ex"
      })

    assert cs.valid?
    assert get_field(cs, :display_name) == "Ex"
  end

  test "document defaults to private visibility and empty provenance" do
    {:ok, user} = Accounts.get_or_create_user("owner@example.com")

    {:ok, doc} =
      %Document{}
      |> Document.create_changeset(%{
        id: Ecto.UUID.generate(),
        user_id: user.id,
        content: %{"title" => "D"}
      })
      |> Repo.insert()

    assert doc.visibility == "private"
    assert doc.provenance == %{}
  end

  test "document rejects an unknown visibility value" do
    cs =
      Document.create_changeset(%Document{}, %{
        id: Ecto.UUID.generate(),
        content: %{"title" => "D"},
        visibility: "secret"
      })

    refute cs.valid?
    assert %{visibility: _} = errors_on(cs)
  end
end
