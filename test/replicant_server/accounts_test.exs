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

  test "get_or_create_user autogenerates distinct ids per email" do
    {:ok, a} = Accounts.get_or_create_user("a@example.com")
    {:ok, b} = Accounts.get_or_create_user("b@example.com")
    assert a.id != b.id
    assert {:ok, _} = Ecto.UUID.cast(a.id)
  end

  test "get_or_create_user finds an existing row regardless of its id" do
    # Legacy rows keep arbitrary (formerly derived) ids; email is the lookup key.
    legacy_id = Ecto.UUID.generate()

    {:ok, _legacy} =
      ReplicantServer.Repo.insert(%ReplicantServer.Accounts.User{
        id: legacy_id,
        email: "legacy@example.com"
      })

    {:ok, user} = Accounts.get_or_create_user("  Legacy@Example.COM ")
    assert user.id == legacy_id
  end

  test "update_user_email changes the email and keeps the id" do
    {:ok, user} = Accounts.get_or_create_user("before@example.com")
    {:ok, updated} = Accounts.update_user_email(user, "  After@Example.COM ")
    assert updated.id == user.id
    assert updated.email == "after@example.com"
    assert Accounts.get_user_by_email("after@example.com").id == user.id
    assert Accounts.get_user_by_email("before@example.com") == nil
  end

  test "update_user_email rejects a taken email" do
    {:ok, _other} = Accounts.get_or_create_user("taken@example.com")
    {:ok, user} = Accounts.get_or_create_user("mine@example.com")
    assert {:error, %Ecto.Changeset{}} = Accounts.update_user_email(user, "taken@example.com")
  end

  test "upsert_user is idempotent by email and updates display_name in place" do
    {:ok, a} = Accounts.upsert_user("  Sean@Sevish.com ", "Sevish")
    {:ok, b} = Accounts.upsert_user("sean@sevish.com", "Sevish (updated)")
    assert a.id == b.id
    assert b.email == "sean@sevish.com"
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

  test "create_user surfaces the email unique constraint (race-retry relies on this shape)" do
    {:ok, _first} = Accounts.create_user("dup@example.com")
    {:error, changeset} = Accounts.create_user("dup@example.com")
    assert {_msg, opts} = changeset.errors[:email]
    assert opts[:constraint] == :unique
  end

  test "a non-unique changeset error is not the email-unique constraint (race-retry propagates it)" do
    {:error, changeset} = Accounts.create_user("")
    {_msg, opts} = changeset.errors[:email]
    refute opts[:constraint] == :unique
  end
end
