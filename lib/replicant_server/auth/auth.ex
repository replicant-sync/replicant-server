defmodule ReplicantServer.Auth do
  @moduledoc """
  Authentication module for HMAC-based API authentication.

  Uses HMAC-SHA256 signatures with a 5-minute timestamp window.
  """

  import Ecto.Query
  alias ReplicantServer.Repo
  alias ReplicantServer.Auth.ApiCredential

  @hmac_window_seconds 300
  @api_key_prefix "rpa_"
  @secret_prefix "rps_"

  # App namespace for deterministic user IDs (matches Rust client)
  @app_namespace_id "com.example.sync-task-list"

  @doc """
  Verifies an HMAC signature for API authentication.

  Returns `{:ok, credential}` if valid, `{:error, reason}` otherwise.
  """
  def verify_hmac(api_key, signature, timestamp, email, body \\ "") do
    with :ok <- verify_timestamp(timestamp),
         {:ok, credential} <- get_active_credential(api_key),
         :ok <- verify_signature(credential.secret, signature, timestamp, email, api_key, body) do
      touch_last_used(credential)
      {:ok, credential}
    end
  end

  @doc """
  Creates an HMAC-SHA256 signature for the given parameters.
  """
  def create_signature(secret, timestamp, email, api_key, body \\ "") do
    message = "#{timestamp}.#{email}.#{api_key}.#{body}"

    :crypto.mac(:hmac, :sha256, secret, message)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Generates a new API credential pair.
  """
  def generate_credentials do
    %{
      api_key: @api_key_prefix <> random_hex(32),
      secret: @secret_prefix <> random_hex(32)
    }
  end

  @doc """
  Creates and persists a new API credential.
  """
  def create_credential(name) do
    creds = generate_credentials()

    %ApiCredential{}
    |> ApiCredential.changeset(Map.put(creds, :name, name))
    |> Repo.insert()
  end

  @doc """
  Generates a deterministic user ID from email using UUID v5.

  This matches the Rust client implementation to ensure the same
  user ID is generated on both client and server.
  """
  def deterministic_user_id(email) do
    app_namespace = UUID.uuid5(:dns, @app_namespace_id)
    UUID.uuid5(app_namespace, email)
  end

  # Private functions

  defp verify_timestamp(timestamp) when is_integer(timestamp) do
    now = System.system_time(:second)
    diff = abs(now - timestamp)

    if diff <= @hmac_window_seconds do
      :ok
    else
      {:error, :timestamp_expired}
    end
  end

  defp verify_timestamp(_), do: {:error, :invalid_timestamp}

  defp get_active_credential(api_key) do
    case Repo.one(from c in ApiCredential, where: c.api_key == ^api_key and c.is_active == true) do
      nil -> {:error, :invalid_api_key}
      credential -> {:ok, credential}
    end
  end

  defp verify_signature(secret, signature, timestamp, email, api_key, body) do
    expected = create_signature(secret, timestamp, email, api_key, body)

    if secure_compare(signature, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false

  defp touch_last_used(credential) do
    credential
    |> ApiCredential.touch_last_used_changeset()
    |> Repo.update()
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes)
    |> Base.encode16(case: :lower)
  end
end
