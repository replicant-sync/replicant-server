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
    normalized = Auth.normalize_email(email)
    user_id = Auth.deterministic_user_id(normalized)

    case get_user(user_id) do
      nil -> create_user(user_id, normalized)
      user -> {:ok, user}
    end
  end

  @doc """
  Mints (or fetches) the deterministic user for `email` and sets `display_name`.

  Idempotent: same email always resolves to the same frozen UUIDv5; the
  display name is updated in place on repeat calls. Used to mint factory
  contributors ahead of the backfill.
  """
  def upsert_user(email, display_name) do
    normalized = Auth.normalize_email(email)
    user_id = Auth.deterministic_user_id(normalized)

    case get_user(user_id) do
      nil ->
        %User{}
        |> User.changeset(%{id: user_id, email: normalized, display_name: display_name})
        |> Repo.insert()

      %User{} = user ->
        user
        |> User.changeset(%{display_name: display_name})
        |> Repo.update()
    end
  end

  @doc """
  The user's presentable name: `display_name` when set, otherwise the local
  part of their email.
  """
  def display_name(%User{display_name: name}) when is_binary(name) and name != "", do: name
  def display_name(%User{email: email}), do: email |> String.split("@") |> hd()

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
    normalized = Auth.normalize_email(email)
    Repo.one(from u in User, where: u.email == ^normalized)
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
