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
end
