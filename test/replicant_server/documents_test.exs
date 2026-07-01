defmodule ReplicantServer.DocumentsTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Documents
  alias ReplicantServer.Accounts

  setup do
    {:ok, user} = Accounts.get_or_create_user("test@example.com")
    %{user: user}
  end

  describe "create_document" do
    test "creates document with event log", %{user: user} do
      doc_id = UUID.uuid4()
      content = %{"title" => "Test", "body" => "Hello"}

      assert {:ok, document} =
               Documents.create_document(user.id, %{id: doc_id, content: content})

      assert document.id == doc_id
      assert document.content == content
      assert document.sync_revision == 1
      assert document.content_hash != nil

      # Verify event was logged
      events = Documents.get_changes_since(user.id, 0)
      assert length(events) == 1
      assert hd(events).event_type == "create"
    end

    test "returns existing document when content is identical", %{user: user} do
      content = %{"title" => "Duplicate", "body" => "Same content"}

      {:ok, first} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})
      {:ok, second} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})

      assert first.id == second.id
      assert Documents.list_user_documents(user.id) |> length() == 1
    end

    test "does not dedup when content differs", %{user: user} do
      {:ok, doc1} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "First"}
        })

      {:ok, doc2} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Second"}
        })

      assert doc1.id != doc2.id
      assert Documents.list_user_documents(user.id) |> length() == 2
    end

    test "does not dedup across different users" do
      {:ok, user_a} = Accounts.get_or_create_user("usera@example.com")
      {:ok, user_b} = Accounts.get_or_create_user("userb@example.com")
      content = %{"title" => "Shared content"}

      {:ok, doc_a} = Documents.create_document(user_a.id, %{id: UUID.uuid4(), content: content})
      {:ok, doc_b} = Documents.create_document(user_b.id, %{id: UUID.uuid4(), content: content})

      assert doc_a.id != doc_b.id
    end

    test "allows recreating content after deletion", %{user: user} do
      content = %{"title" => "Revived"}

      {:ok, original} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})
      {:ok, _} = Documents.delete_document(user.id, original.id)

      {:ok, recreated} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})

      assert recreated.id != original.id
      assert Documents.list_user_documents(user.id) |> length() == 1
    end

    test "dedup returns existing even when new ID is provided", %{user: user} do
      content = %{"title" => "Stable"}
      original_id = UUID.uuid4()
      new_id = UUID.uuid4()

      {:ok, first} = Documents.create_document(user.id, %{id: original_id, content: content})
      {:ok, second} = Documents.create_document(user.id, %{id: new_id, content: content})

      # Should return the original, not create with the new ID
      assert second.id == original_id
      assert first.id == second.id
    end

    test "returns conflict for duplicate ID", %{user: user} do
      doc_id = UUID.uuid4()
      content = %{"title" => "Test"}

      {:ok, _} = Documents.create_document(user.id, %{id: doc_id, content: content})

      assert {:error, :conflict, existing} =
               Documents.create_document(user.id, %{id: doc_id, content: %{"title" => "Other"}})

      assert existing.id == doc_id
    end
  end

  describe "update_document" do
    test "updates with valid content_hash", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Original", "count" => 0}
        })

      patch = [%{"op" => "replace", "path" => "/title", "value" => "Updated"}]

      assert {:ok, updated} = Documents.update_document(user.id, doc.id, patch, doc.content_hash)
      assert updated.content["title"] == "Updated"
      assert updated.sync_revision == 2
    end

    test "fails on hash mismatch", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Original"}
        })

      patch = [%{"op" => "replace", "path" => "/title", "value" => "Updated"}]

      assert {:error, :hash_mismatch, _current} =
               Documents.update_document(user.id, doc.id, patch, "wrong_hash")
    end

    test "logs forward and reverse patches", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Original"}
        })

      patch = [%{"op" => "replace", "path" => "/title", "value" => "Updated"}]
      {:ok, _} = Documents.update_document(user.id, doc.id, patch, doc.content_hash)

      events = Documents.get_changes_since(user.id, 0)
      update_event = Enum.find(events, &(&1.event_type == "update"))

      assert update_event.forward_patch == patch
      assert update_event.reverse_patch != nil
    end
  end

  describe "delete_document" do
    test "soft deletes and logs event", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "To Delete"}
        })

      assert {:ok, deleted} = Documents.delete_document(user.id, doc.id)
      assert deleted.deleted_at != nil

      # Should not appear in list
      assert Documents.list_user_documents(user.id) == []

      # Event logged
      events = Documents.get_changes_since(user.id, 0)
      delete_event = Enum.find(events, &(&1.event_type == "delete"))
      assert delete_event != nil
    end
  end

  describe "public document dedup" do
    test "returns existing public document when content is identical" do
      content = %{"title" => "Public Preset", "data" => [1, 2, 3]}

      {:ok, first} = Documents.create_public_document(%{content: content})
      {:ok, second} = Documents.create_public_document(%{content: content})

      assert first.id == second.id
      assert Documents.list_public_documents() |> length() == 1
    end

    test "does not dedup public and user documents", %{user: user} do
      content = %{"title" => "Cross-boundary"}

      {:ok, public} = Documents.create_public_document(%{content: content})
      {:ok, user_doc} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})

      assert public.id != user_doc.id
    end
  end

  describe "copy_document_to_user" do
    test "copies a single document to another user", %{user: user} do
      {:ok, target} = Accounts.get_or_create_user("target@example.com")
      content = %{"title" => "Copyable", "data" => "hello"}

      {:ok, original} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})
      {:ok, copied} = Documents.copy_document_to_user(original.id, user.id, target.id)

      assert copied.content == original.content
      assert copied.id != original.id
      assert Documents.list_user_documents(target.id) |> length() == 1
    end

    test "returns error for nonexistent document", %{user: user} do
      {:ok, target} = Accounts.get_or_create_user("target2@example.com")

      assert {:error, :not_found} =
               Documents.copy_document_to_user(UUID.uuid4(), user.id, target.id)
    end

    test "skips if identical content already exists for target", %{user: user} do
      {:ok, target} = Accounts.get_or_create_user("target3@example.com")
      content = %{"title" => "Already There"}

      {:ok, original} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})
      {:ok, _existing} = Documents.create_document(target.id, %{id: UUID.uuid4(), content: content})

      {:ok, result} = Documents.copy_document_to_user(original.id, user.id, target.id)

      # Should not create a duplicate
      assert Documents.list_user_documents(target.id) |> length() == 1
      assert result.content == content
    end
  end

  describe "copy_all_documents" do
    test "copies all documents between users", %{user: user} do
      {:ok, target} = Accounts.get_or_create_user("bulk-target@example.com")

      for i <- 1..3 do
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Doc #{i}"}
        })
      end

      assert {:ok, %{copied: 3, skipped: 0}} =
               Documents.copy_all_documents(user.id, target.id)

      assert Documents.list_user_documents(target.id) |> length() == 3
    end

    test "skips already-existing documents", %{user: user} do
      {:ok, target} = Accounts.get_or_create_user("bulk-target2@example.com")
      shared_content = %{"title" => "Shared"}

      Documents.create_document(user.id, %{id: UUID.uuid4(), content: shared_content})
      Documents.create_document(user.id, %{id: UUID.uuid4(), content: %{"title" => "Unique"}})

      # Pre-create the shared one in target
      Documents.create_document(target.id, %{id: UUID.uuid4(), content: shared_content})

      assert {:ok, %{copied: 1, skipped: 1}} =
               Documents.copy_all_documents(user.id, target.id)

      assert Documents.list_user_documents(target.id) |> length() == 2
    end

    test "handles empty source gracefully", %{user: user} do
      {:ok, target} = Accounts.get_or_create_user("bulk-target3@example.com")

      assert {:ok, %{copied: 0, skipped: 0}} =
               Documents.copy_all_documents(user.id, target.id)
    end
  end

  describe "copy_all_documents_by_email" do
    test "resolves emails and copies documents" do
      {:ok, source} = Accounts.get_or_create_user("email-source@example.com")

      Documents.create_document(source.id, %{
        id: UUID.uuid4(),
        content: %{"title" => "Via Email"}
      })

      assert {:ok, %{copied: 1, skipped: 0}} =
               Documents.copy_all_documents_by_email("email-source@example.com", "email-target@example.com")

      {:ok, target} = Accounts.get_or_create_user("email-target@example.com")
      assert Documents.list_user_documents(target.id) |> length() == 1
    end
  end

  describe "content hash" do
    test "computes consistent hash" do
      content = %{"a" => 1, "b" => 2}

      hash1 = Documents.compute_hash(content)
      hash2 = Documents.compute_hash(content)

      assert hash1 == hash2
      assert String.length(hash1) == 64
    end

    test "verifies hash correctly" do
      content = %{"test" => "data"}
      hash = Documents.compute_hash(content)

      assert Documents.verify_hash(content, hash)
      refute Documents.verify_hash(%{"other" => "data"}, hash)
    end
  end
end
