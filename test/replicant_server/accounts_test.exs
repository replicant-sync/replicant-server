defmodule ReplicantServer.AccountsTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Accounts

  test "get_or_create_user persists the normalized email" do
    {:ok, user} = Accounts.get_or_create_user("  Casey@Example.COM ")
    assert user.email == "casey@example.com"
  end

  test "get_or_create_user is idempotent across case/whitespace variants" do
    {:ok, a} = Accounts.get_or_create_user("casey@example.com")
    {:ok, b} = Accounts.get_or_create_user("  CASEY@example.com ")
    assert a.id == b.id
  end

  test "get_user_by_email finds a user regardless of input casing/whitespace" do
    {:ok, user} = Accounts.get_or_create_user("dana@example.com")
    assert Accounts.get_user_by_email("  Dana@Example.com ").id == user.id
  end

  test "upsert_user mints the frozen id and sets display_name" do
    {:ok, user} = Accounts.upsert_user("rr@robertrich.com", "Robert Rich")
    assert user.id == "26e545b7-b039-5de9-8f38-f302fd9da444"
    assert user.email == "rr@robertrich.com"
    assert user.display_name == "Robert Rich"
  end

  test "upsert_user is idempotent and updates the display_name in place" do
    {:ok, a} = Accounts.upsert_user("  Sean@Sevish.com ", "Sevish")
    {:ok, b} = Accounts.upsert_user("sean@sevish.com", "Sevish (updated)")
    assert a.id == b.id
    assert b.id == "38795f16-1bf4-5a61-bbd1-df366c140494"
    assert b.display_name == "Sevish (updated)"
  end

  test "changeset is valid without an id and insert autogenerates one" do
    changeset =
      ReplicantServer.Accounts.User.changeset(%ReplicantServer.Accounts.User{}, %{
        email: "auto@example.com"
      })

    assert changeset.valid?

    {:ok, user} = ReplicantServer.Repo.insert(changeset)
    assert {:ok, _} = Ecto.UUID.cast(user.id)
  end

  test "changeset accepts an optional unique username" do
    {:ok, a} =
      %ReplicantServer.Accounts.User{}
      |> ReplicantServer.Accounts.User.changeset(%{email: "u1@example.com", username: "u1"})
      |> ReplicantServer.Repo.insert()

    assert a.username == "u1"

    {:error, changeset} =
      %ReplicantServer.Accounts.User{}
      |> ReplicantServer.Accounts.User.changeset(%{email: "u2@example.com", username: "u1"})
      |> ReplicantServer.Repo.insert()

    assert {"has already been taken", _} = changeset.errors[:username]
  end
end
