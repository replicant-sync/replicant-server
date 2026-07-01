defmodule ReplicantServer.AuthTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Auth

  describe "HMAC signature" do
    test "create_signature generates consistent signatures" do
      secret = "rps_test_secret"
      timestamp = 1704067200
      email = "test@example.com"
      api_key = "rpa_test_key"

      sig1 = Auth.create_signature(secret, timestamp, email, api_key)
      sig2 = Auth.create_signature(secret, timestamp, email, api_key)

      assert sig1 == sig2
      assert String.length(sig1) == 64
    end

    test "different inputs produce different signatures" do
      secret = "rps_test_secret"
      timestamp = 1704067200
      email = "test@example.com"
      api_key = "rpa_test_key"

      sig1 = Auth.create_signature(secret, timestamp, email, api_key)
      sig2 = Auth.create_signature(secret, timestamp, "other@example.com", api_key)

      assert sig1 != sig2
    end
  end

  describe "deterministic_user_id" do
    test "generates consistent UUIDs for same email" do
      email = "test@example.com"

      id1 = Auth.deterministic_user_id(email)
      id2 = Auth.deterministic_user_id(email)

      assert id1 == id2
      assert String.length(id1) == 36
    end

    test "generates different UUIDs for different emails" do
      id1 = Auth.deterministic_user_id("alice@example.com")
      id2 = Auth.deterministic_user_id("bob@example.com")

      assert id1 != id2
    end

    test "derives the frozen golden vectors for namespace com.nodeaudio.entonal" do
      assert Auth.deterministic_user_id("test@example.com") ==
               "71b2b712-7878-56ee-8323-43809b8198a5"

      assert Auth.deterministic_user_id("alice@example.com") ==
               "af665bed-e8e7-5b1f-ba4f-9343fefde4bb"

      assert Auth.deterministic_user_id("bob@example.com") ==
               "22025cd4-e01b-560e-8004-8614ef9bd52e"
    end

    test "case and surrounding whitespace do not change the derived id" do
      base = Auth.deterministic_user_id("alice@example.com")
      assert Auth.deterministic_user_id("  Alice@Example.COM  ") == base
      assert Auth.deterministic_user_id("ALICE@EXAMPLE.COM") == base
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
