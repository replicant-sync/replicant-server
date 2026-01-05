defmodule ReplicantServer.Accounts do
  @moduledoc """
  The Accounts context for user management.
  """

  import Ecto.Query
  alias ReplicantServer.Repo
  alias ReplicantServer.Accounts.User
  alias ReplicantServer.Auth

  @doc """
  Gets or creates a user by email.

  Uses deterministic UUID v5 to ensure consistent user IDs
  between client and server.
  """
  def get_or_create_user(email) do
    user_id = Auth.deterministic_user_id(email)

    case get_user(user_id) do
      nil -> create_user(user_id, email)
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by ID.
  """
  def get_user(id) do
    Repo.get(User, id)
  end

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) do
    Repo.one(from u in User, where: u.email == ^email)
  end

  @doc """
  Creates a user with the given ID and email.
  """
  def create_user(id, email) do
    %User{}
    |> User.changeset(%{id: id, email: email})
    |> Repo.insert()
  end

  @doc """
  Updates a user's last_seen_at timestamp.
  """
  def touch_last_seen(user) do
    user
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
    |> Repo.update()
  end
end
