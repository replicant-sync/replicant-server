defmodule ReplicantServer.DocumentsTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Documents
  alias ReplicantServer.Accounts
  alias ReplicantServer.{Feed, Scopes}
  alias ReplicantServer.Feed.ChangeEvent
  alias ReplicantServer.Documents.Document
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    {:ok, user} = Accounts.get_or_create_user("test@example.com")
    %{user: user}
  end

  defp events_for(doc_id) do
    Repo.all(from e in ChangeEvent, where: e.doc_id == ^doc_id, order_by: e.seq)
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

      assert [event] = events_for(doc_id)
      assert {event.scope, event.kind, event.seq} == {"own:" <> user.id, "upsert", document.seq}
      assert event.hash == document.content_hash
    end

    test "identical content under a new id is a second document", %{user: user} do
      content = %{"title" => "Duplicate", "body" => "Same content"}
      {:ok, first} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})
      {:ok, second} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})

      assert first.id != second.id
      assert Documents.list_user_documents(user.id) |> length() == 2
    end

    test "a deleted document's id stays taken", %{user: user} do
      {:ok, doc} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: %{"a" => 1}})
      {:ok, _} = Documents.delete_document(user.id, doc.id)

      assert {:error, :conflict, _} =
               Documents.create_document(user.id, %{id: doc.id, content: %{}})
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

    test "returns conflict for duplicate ID", %{user: user} do
      doc_id = UUID.uuid4()
      content = %{"title" => "Test"}

      {:ok, _} = Documents.create_document(user.id, %{id: doc_id, content: content})

      assert {:error, :conflict, existing} =
               Documents.create_document(user.id, %{id: doc_id, content: %{"title" => "Other"}})

      assert existing.id == doc_id
    end

    test "a non-string title does not fail the insert", %{user: user} do
      assert {:ok, doc} =
               Documents.create_document(user.id, %{id: UUID.uuid4(), content: %{"title" => 123}})

      assert doc.title == nil
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

    test "rejects nil content_hash", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Original"}
        })

      patch = [%{"op" => "replace", "path" => "/title", "value" => "Updated"}]

      assert {:error, :missing_hash} = Documents.update_document(user.id, doc.id, patch, nil)
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

    test "appends an upsert with the new hash and seq", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{id: UUID.uuid4(), content: %{"title" => "Original"}})

      patch = [%{"op" => "replace", "path" => "/title", "value" => "Updated"}]
      {:ok, updated} = Documents.update_document(user.id, doc.id, patch, doc.content_hash)

      assert [_create, event] = events_for(doc.id)

      assert {event.kind, event.seq, event.hash, event.prev_seq} ==
               {"upsert", updated.seq, updated.content_hash, doc.seq}
    end

    test "another user's document is forbidden and a publication is read-only", %{user: user} do
      {:ok, other} = Accounts.get_or_create_user("other-writer@example.com")
      {:ok, doc} = Documents.create_document(other.id, %{id: UUID.uuid4(), content: %{"t" => 1}})
      patch = [%{"op" => "replace", "path" => "/t", "value" => 2}]

      assert {:error, :forbidden} =
               Documents.update_document(user.id, doc.id, patch, doc.content_hash)

      pub =
        Repo.insert!(%Document{
          id: UUID.uuid4(),
          content: %{"t" => 1},
          content_hash: "h",
          read_only: true
        })

      assert {:error, :forbidden} = Documents.update_document(user.id, pub.id, patch, "h")
    end

    test "a malformed patch is invalid_patch", %{user: user} do
      {:ok, doc} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: %{"t" => 1}})
      bad = [%{"op" => "replace", "path" => "/missing/deep", "value" => 2, "junk" => true}]

      assert {:error, :invalid_patch} =
               Documents.update_document(user.id, doc.id, bad, doc.content_hash)

      assert {:error, :invalid_patch} =
               Documents.update_document(user.id, doc.id, "nope", doc.content_hash)
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

      assert [%{kind: "upsert"}, %{kind: "delete", seq: seq}] = events_for(doc.id)
      assert seq == deleted.seq
    end

    test "deleting keeps the document's events and the row as a tombstone", %{user: user} do
      {:ok, doc} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: %{"t" => 1}})
      {:ok, _} = Documents.delete_document(user.id, doc.id)
      assert length(events_for(doc.id)) == 2
      assert Repo.get(Document, doc.id).deleted_at
      assert {:error, :not_found} = Documents.delete_document(user.id, doc.id)
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

    test "copies even when identical content already exists for target", %{user: user} do
      {:ok, target} = Accounts.get_or_create_user("target3@example.com")
      content = %{"title" => "Already There"}

      {:ok, original} = Documents.create_document(user.id, %{id: UUID.uuid4(), content: content})

      {:ok, _existing} =
        Documents.create_document(target.id, %{id: UUID.uuid4(), content: content})

      {:ok, result} = Documents.copy_document_to_user(original.id, user.id, target.id)

      assert Documents.list_user_documents(target.id) |> length() == 2
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

    test "copies every document even when the target has identical content", %{user: user} do
      {:ok, target} = Accounts.get_or_create_user("bulk-target2@example.com")
      shared_content = %{"title" => "Shared"}

      Documents.create_document(user.id, %{id: UUID.uuid4(), content: shared_content})
      Documents.create_document(user.id, %{id: UUID.uuid4(), content: %{"title" => "Unique"}})

      # Pre-create the shared one in target
      Documents.create_document(target.id, %{id: UUID.uuid4(), content: shared_content})

      assert {:ok, %{copied: 2, skipped: 0}} =
               Documents.copy_all_documents(user.id, target.id)

      assert Documents.list_user_documents(target.id) |> length() == 3
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
               Documents.copy_all_documents_by_email(
                 "email-source@example.com",
                 "email-target@example.com"
               )

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

    test "canonical encoding matches plain Jason.encode!/1 for small (<=32 key) maps" do
      content = %{
        "type" => "tuning",
        "title" => "Interop",
        "zeta" => 1,
        "alpha" => %{"nested_z" => [1, 2, 3], "nested_a" => "x"},
        "pitches" => ["1/1", "9/8", "5/4"],
        "referenceFrequency" => 261.626
      }

      legacy_hash =
        content
        |> Jason.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert Documents.compute_hash(content) == legacy_hash
    end
  end

  describe "envelope attribution" do
    test "create_document stamps author_name from the owner's presentable name" do
      {:ok, user} = ReplicantServer.Accounts.get_or_create_user("carla@example.com")

      {:ok, doc} =
        Documents.create_document(user.id, %{
          "id" => Ecto.UUID.generate(),
          "content" => %{"title" => "Carla's tuning"}
        })

      assert doc.author_name == "carla"
    end

    test "create_document keeps an explicitly provided author_name (copy path)" do
      {:ok, user} = ReplicantServer.Accounts.get_or_create_user("carla@example.com")

      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: Ecto.UUID.generate(),
          content: %{"title" => "Copy"},
          author_name: "Sevish"
        })

      assert doc.author_name == "Sevish"
    end
  end

  describe "write lock ordering (real transactions)" do
    setup do
      {doc_id, user_id} =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, user} =
            Accounts.get_or_create_user(
              "lock-order-#{System.unique_integer([:positive])}@example.com"
            )

          {:ok, doc} =
            Documents.create_document(user.id, %{id: Ecto.UUID.generate(), content: %{"v" => 0}})

          {doc.id, user.id}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from e in ChangeEvent, where: e.doc_id == ^doc_id)
          Repo.delete_all(from d in Document, where: d.id == ^doc_id)
          Repo.delete_all(from u in Accounts.User, where: u.id == ^user_id)
        end)
      end)

      %{doc_id: doc_id, user_id: user_id}
    end

    test "replace_content takes the document row lock before it waits on the scope lock", %{
      doc_id: doc_id,
      user_id: user_id
    } do
      scope = Scopes.own(user_id)
      parent = self()

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Feed.lock_scopes([scope])
              send(parent, :scope_locked)

              receive do
                :release -> :ok
              end
            end)
          end)
        end)

      assert_receive :scope_locked

      writer =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            doc = Repo.get!(Document, doc_id)
            Documents.replace_content(doc, %{"v" => 1})
          end)
        end)

      refute Task.yield(writer, 200)

      # The writer already holds the document row lock (taken before it blocked on the
      # scope lock inside Feed.record/2), so a NOWAIT probe from another connection fails.
      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               Sandbox.unboxed_run(Repo, fn ->
                 Repo.query("SELECT id FROM documents WHERE id = $1 FOR UPDATE NOWAIT", [
                   Ecto.UUID.dump!(doc_id)
                 ])
               end)

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder)
      assert {:ok, updated} = Task.await(writer)
      assert updated.content == %{"v" => 1}
    end
  end
end
