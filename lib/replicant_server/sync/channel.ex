defmodule ReplicantServer.Sync.Channel do
  @moduledoc "Protocol v2 sync channel: one per connection, topic `sync:v2`."

  use Phoenix.Channel

  alias ReplicantServer.Auth
  alias ReplicantServer.Sync.Envelope

  require Logger

  @protocol_version 2

  @impl true
  def join("sync:v2", params, socket) do
    case authenticate(params) do
      {:ok, user_id} ->
        {:ok, %{user_id: user_id, protocol_version: @protocol_version},
         assign(socket, user_id: user_id, scopes: MapSet.new())}

      {:error, code} ->
        Logger.warning("Join rejected: #{code}")
        {:error, Envelope.error(code)}
    end
  end

  defp authenticate(%{
         "email" => email,
         "api_key" => api_key,
         "signature" => signature,
         "timestamp" => timestamp
       }) do
    case Auth.verify_hmac(api_key, signature, timestamp, email) do
      {:ok, %{user_id: nil}} -> {:error, "auth_invalid"}
      {:ok, %{user_id: user_id}} -> {:ok, user_id}
      {:error, :timestamp_expired} -> {:error, "clock_skew"}
      {:error, _reason} -> {:error, "auth_invalid"}
    end
  end

  defp authenticate(_params), do: {:error, "auth_invalid"}
end
