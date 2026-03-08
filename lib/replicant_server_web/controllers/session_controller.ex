defmodule ReplicantServerWeb.SessionController do
  use ReplicantServerWeb, :controller

  alias ReplicantServer.Accounts

  def new(conn, _params) do
    render(conn, :new)
  end

  def create(conn, %{"email" => email}) when is_binary(email) and email != "" do
    case Accounts.get_or_create_user(String.trim(email)) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Logged in as #{user.email}")
        |> redirect(to: ~p"/documents")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not log in")
        |> redirect(to: ~p"/login")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Email is required")
    |> redirect(to: ~p"/login")
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, "Logged out")
    |> redirect(to: ~p"/login")
  end
end
