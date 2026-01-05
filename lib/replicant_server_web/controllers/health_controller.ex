defmodule ReplicantServerWeb.HealthController do
  use ReplicantServerWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end
end
