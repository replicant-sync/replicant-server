defmodule ReplicantServer.Auth do
  @moduledoc """
  Authentication module for HMAC-based API authentication.

  Uses HMAC-SHA256 signatures with a 5-minute timestamp window.
  """

  import Ecto.Query
  alias ReplicantServer.Repo
  alias ReplicantServer.Accounts
  alias ReplicantServer.Auth.{ApiCredential, EnrollmentToken}

  @hmac_window_seconds 300
  @api_key_prefix "rpa_"
  @secret_prefix "rps_"
  @enrollment_token_bytes 8
  @enrollment_ttl_seconds 900

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
  Mints a one-time enrollment token for `email`, creating the user if needed.
  Stores only the token's hash; returns the plaintext token for delivery.
  Always succeeds for a well-formed email (no account enumeration).
  """
  def request_enrollment(email) do
    normalized = normalize_email(email)

    with {:ok, user} <- Accounts.get_or_create_user(normalized) do
      token = generate_enrollment_token()

      attrs = %{
        user_id: user.id,
        token_hash: hash_token(token),
        expires_at: DateTime.add(DateTime.utc_now(), @enrollment_ttl_seconds, :second)
      }

      case %EnrollmentToken{} |> EnrollmentToken.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> {:ok, token}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Exchanges a valid, unused, unexpired enrollment token (bound to `email`'s user)
  for a freshly minted per-user API credential. Marks the token used atomically.
  Returns `{:error, :invalid_token}` on any failure (no distinguishing detail).
  """
  def claim_enrollment(email, token) do
    normalized = normalize_email(email)
    hash = hash_token(token)
    now = DateTime.utc_now()

    query =
      from t in EnrollmentToken,
        where: t.token_hash == ^hash and is_nil(t.used_at) and t.expires_at > ^now,
        preload: [:user]

    case Repo.one(query) do
      %EnrollmentToken{user: %{email: ^normalized} = user} = enrollment ->
        claim_token(enrollment, user)

      _ ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Normalizes an email for storage and lookup: trim surrounding whitespace,
  then Unicode-downcase. Deliberately does NOT do provider-specific alias
  canonicalization (e.g. Gmail dots).
  """
  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  # Private functions

  defp generate_enrollment_token do
    :crypto.strong_rand_bytes(@enrollment_token_bytes)
    |> Base.encode32(padding: false, case: :upper)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp claim_token(enrollment, user) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(t in EnrollmentToken, where: t.id == ^enrollment.id and is_nil(t.used_at)),
        set: [used_at: now, updated_at: now]
      )

    case count do
      1 -> mint_credential(user)
      0 -> {:error, :invalid_token}
    end
  end

  defp mint_credential(user) do
    creds = generate_credentials()
    attrs = Map.merge(creds, %{name: "device:#{user.email}", user_id: user.id})

    case %ApiCredential{} |> ApiCredential.changeset(attrs) |> Repo.insert() do
      {:ok, _credential} -> {:ok, creds}
      {:error, changeset} -> {:error, changeset}
    end
  end

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
