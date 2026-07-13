defmodule ReplicantServer.AuthTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Auth
  alias ReplicantServer.Auth.{ApiCredential, EnrollmentToken}
  alias ReplicantServer.Repo

  describe "request_enrollment/1" do
    test "mints a single-use token, stores only its hash, and returns the plaintext" do
      {:ok, token} = Auth.request_enrollment("Alice@Example.com")

      assert is_binary(token) and byte_size(token) >= 10

      stored = Repo.one(EnrollmentToken)
      refute stored.token_hash == token
      assert stored.token_hash == :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      assert is_nil(stored.used_at)
      assert DateTime.compare(stored.expires_at, DateTime.utc_now()) == :gt

      user = ReplicantServer.Accounts.get_user(stored.user_id)
      assert user.email == "alice@example.com"
    end

    test "reuses the existing user for a known email" do
      {:ok, user} = ReplicantServer.Accounts.get_or_create_user("bob@example.com")
      {:ok, _token} = Auth.request_enrollment("bob@example.com")

      assert Repo.one(EnrollmentToken).user_id == user.id
    end
  end

  describe "claim_enrollment/2" do
    setup do
      {:ok, token} = Auth.request_enrollment("carol@example.com")
      %{token: token}
    end

    test "exchanges a valid token for a per-user credential", %{token: token} do
      {:ok, creds} = Auth.claim_enrollment("carol@example.com", token)

      assert creds.api_key =~ ~r/^rpa_[a-f0-9]{64}$/
      assert creds.secret =~ ~r/^rps_[a-f0-9]{64}$/

      credential = Repo.get_by(ApiCredential, api_key: creds.api_key)
      user = ReplicantServer.Accounts.get_user_by_email("carol@example.com")
      assert credential.user_id == user.id

      assert Repo.one(EnrollmentToken).used_at != nil
    end

    test "rejects a token that was already claimed", %{token: token} do
      {:ok, _} = Auth.claim_enrollment("carol@example.com", token)
      assert {:error, :invalid_token} = Auth.claim_enrollment("carol@example.com", token)
    end

    test "rejects a wrong/unknown token" do
      assert {:error, :invalid_token} =
               Auth.claim_enrollment("carol@example.com", "NOTAREALTOKEN")
    end

    test "rejects when the email does not match the token's user", %{token: token} do
      assert {:error, :invalid_token} = Auth.claim_enrollment("mallory@example.com", token)
    end

    test "rejects an expired token", %{token: token} do
      Repo.update_all(EnrollmentToken,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:error, :invalid_token} = Auth.claim_enrollment("carol@example.com", token)
    end

    test "claim_enrollment returns the canonical user id with the credentials" do
      {:ok, token} = Auth.request_enrollment("claimid@example.com")
      {:ok, user} = ReplicantServer.Accounts.get_or_create_user("claimid@example.com")
      assert {:ok, creds} = Auth.claim_enrollment("claimid@example.com", token)
      assert creds.user_id == user.id
    end
  end

  describe "HMAC signature" do
    test "create_signature generates consistent signatures" do
      secret = "rps_test_secret"
      timestamp = 1_704_067_200
      email = "test@example.com"
      api_key = "rpa_test_key"

      sig1 = Auth.create_signature(secret, timestamp, email, api_key)
      sig2 = Auth.create_signature(secret, timestamp, email, api_key)

      assert sig1 == sig2
      assert String.length(sig1) == 64
    end

    test "different inputs produce different signatures" do
      secret = "rps_test_secret"
      timestamp = 1_704_067_200
      email = "test@example.com"
      api_key = "rpa_test_key"

      sig1 = Auth.create_signature(secret, timestamp, email, api_key)
      sig2 = Auth.create_signature(secret, timestamp, "other@example.com", api_key)

      assert sig1 != sig2
    end
  end

  describe "generate_credentials" do
    test "generates valid credential format" do
      creds = Auth.generate_credentials()

      assert String.starts_with?(creds.api_key, "rpa_")
      assert String.starts_with?(creds.secret, "rps_")
      assert String.length(creds.api_key) == 68
      assert String.length(creds.secret) == 68
    end
  end

  describe "verify_hmac" do
    setup do
      {:ok, credential} = Auth.create_credential("Test App")
      %{credential: credential}
    end

    test "accepts valid signature", %{credential: cred} do
      timestamp = System.system_time(:second)
      email = "test@example.com"
      signature = Auth.create_signature(cred.secret, timestamp, email, cred.api_key)

      assert {:ok, _} = Auth.verify_hmac(cred.api_key, signature, timestamp, email)
    end

    test "rejects invalid signature", %{credential: cred} do
      timestamp = System.system_time(:second)
      email = "test@example.com"

      assert {:error, :invalid_signature} =
               Auth.verify_hmac(cred.api_key, "invalid_signature", timestamp, email)
    end

    test "rejects expired timestamp", %{credential: cred} do
      timestamp = System.system_time(:second) - 600
      email = "test@example.com"
      signature = Auth.create_signature(cred.secret, timestamp, email, cred.api_key)

      assert {:error, :timestamp_expired} =
               Auth.verify_hmac(cred.api_key, signature, timestamp, email)
    end

    test "rejects unknown api_key" do
      timestamp = System.system_time(:second)
      email = "test@example.com"

      assert {:error, :invalid_api_key} =
               Auth.verify_hmac("rpa_unknown", "signature", timestamp, email)
    end
  end

  describe "normalize_email" do
    test "trims surrounding whitespace and downcases" do
      assert Auth.normalize_email("  Foo@Bar.COM ") == "foo@bar.com"
    end

    test "is idempotent" do
      once = Auth.normalize_email("  Foo@Bar.COM ")
      assert Auth.normalize_email(once) == once
    end
  end
end
