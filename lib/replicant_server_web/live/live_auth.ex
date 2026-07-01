defmodule ReplicantServerWeb.LiveAuth do
  @moduledoc """
  on_mount hook that loads current_user from session or redirects to /login.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias ReplicantServer.Accounts

  def on_mount(:default, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user_id ->
        case Accounts.get_user(user_id) do
          nil ->
            {:halt, redirect(socket, to: "/login")}

          user ->
            {:cont, assign(socket, :current_user, user)}
        end
    end
  end
end
