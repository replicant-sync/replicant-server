defmodule ReplicantServer.Sync.UploadTest do
  use ReplicantServer.DataCase

  alias Ecto.Adapters.SQL.Sandbox
  alias ReplicantServer.{Accounts, Documents}
  alias ReplicantServer.Accounts.User
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Feed.{ChangeEvent, UploadResult}
  alias ReplicantServer.Sync.Upload

  @client_id "0190a0a0-0000-7000-8000-00000000c1d0"

  setup do
    {:ok, user} = Accounts.get_or_create_user("upload@example.com")
    %{user: user}
  end

  defp params(kind, doc_id, extra \\ %{}) do
    Map.merge(%{"upload_id" => Ecto.UUID.generate(), "doc_id" => doc_id, "kind" => kind}, extra)
  end

  defp upload(user, kind, doc_id, extra \\ %{}),
    do: Upload.run(user.id, @client_id, params(kind, doc_id, extra))

  defp create(user, content \\ %{"title" => "T"}) do
    {:ok, reply} = upload(user, "create", Ecto.UUID.generate(), %{"payload" => content})
    reply
  end

  defp events(doc_id),
    do: Repo.all(from e in ChangeEvent, where: e.doc_id == ^doc_id, order_by: e.seq)

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()
  defp title_patch(title), do: [%{"op" => "replace", "path" => "/title", "value" => title}]

  describe "create" do
    test "stores the document and records an upsert tagged with the upload", %{user: user} do
      p = params("create", Ecto.UUID.generate(), %{"payload" => %{"title" => "New"}})
      doc_id = p["doc_id"]
      upload_id = p["upload_id"]
      assert {:ok, reply} = Upload.run(user.id, @client_id, p)

      assert %{
               doc_id: ^doc_id,
               owner_id: owner,
               read_only: false,
               hash: hash,
               seq: seq,
               content: %{"title" => "New"}
             } = reply

      assert owner == user.id
      assert hash == Documents.compute_hash(%{"title" => "New"})

      assert [
               %{
                 kind: "upsert",
                 seq: ^seq,
                 upload_id: ^upload_id,
                 client_id: @client_id,
                 hash: ^hash
               }
             ] = events(doc_id)
    end

    test "identical content under a new id is a second document", %{user: user} do
      a = create(user, %{"title" => "Same"})
      b = create(user, %{"title" => "Same"})
      assert a.doc_id != b.doc_id
      assert Repo.aggregate(from(d in Document, where: d.user_id == ^user.id), :count) == 2
    end

    test "an existing id is rejected as exists with its owner, even after delete", %{user: user} do
      mine = create(user)

      assert {:error, %{code: "exists", is_fatal: false, existing_owner: owner}} =
               upload(user, "create", mine.doc_id, %{"payload" => %{}})

      assert owner == user.id

      {:ok, other} = Accounts.get_or_create_user("upload-other@example.com")

      assert {:error, %{code: "exists", existing_owner: ^owner}} =
               upload(other, "create", mine.doc_id, %{"payload" => %{}})

      {:ok, _} = upload(user, "delete", mine.doc_id)

      assert {:error, %{code: "exists"}} =
               upload(user, "create", mine.doc_id, %{"payload" => %{}})
    end

    test "a retried create returns the stored reply and writes nothing", %{user: user} do
      p = params("create", Ecto.UUID.generate(), %{"payload" => %{"title" => "Once"}})
      {:ok, first} = Upload.run(user.id, @client_id, p)
      {:ok, again} = Upload.run(user.id, @client_id, p)
      assert json(again) == json(first)
      assert length(events(p["doc_id"])) == 1
    end
  end

  describe "update" do
    test "applies a patch on the current base", %{user: user} do
      doc = create(user)

      assert {:ok, %{content: %{"title" => "Next"}, seq: seq, hash: hash}} =
               upload(user, "update", doc.doc_id, %{
                 "base_hash" => doc.hash,
                 "payload" => title_patch("Next")
               })

      assert seq > doc.seq
      assert hash == Documents.compute_hash(%{"title" => "Next"})
    end

    test "a stale base gets hash_mismatch with the current hash and seq", %{user: user} do
      doc = create(user)

      assert {:error,
              %{
                code: "hash_mismatch",
                is_fatal: false,
                current_hash: h,
                current_seq: s,
                doc_id: id
              }} =
               upload(user, "update", doc.doc_id, %{
                 "base_hash" => "stale",
                 "payload" => title_patch("x")
               })

      assert {h, s, id} == {doc.hash, doc.seq, doc.doc_id}
    end

    test "a retried update returns the stored reply and writes nothing", %{user: user} do
      doc = create(user)

      p =
        params("update", doc.doc_id, %{"base_hash" => doc.hash, "payload" => title_patch("Once")})

      {:ok, first} = Upload.run(user.id, @client_id, p)
      {:ok, again} = Upload.run(user.id, @client_id, p)
      assert json(again) == json(first)
      assert length(events(doc.doc_id)) == 2
    end

    test "the same upload_id on a different base is processed, not answered from storage", %{
      user: user
    } do
      doc = create(user)

      p =
        params("update", doc.doc_id, %{"base_hash" => doc.hash, "payload" => title_patch("First")})

      {:ok, _} = Upload.run(user.id, @client_id, p)

      assert {:error, %{code: "hash_mismatch"}} =
               Upload.run(user.id, @client_id, %{p | "base_hash" => "other-base"})
    end

    test "missing base_hash or a malformed patch is validation", %{user: user} do
      doc = create(user)

      assert {:error, %{code: "validation"}} =
               upload(user, "update", doc.doc_id, %{"payload" => title_patch("x")})

      assert {:error, %{code: "validation"}} =
               upload(user, "update", doc.doc_id, %{"base_hash" => doc.hash, "payload" => "x"})

      bad = [%{"op" => "replace", "path" => "/no/such", "value" => 1}]

      assert {:error, %{code: "validation"}} =
               upload(user, "update", doc.doc_id, %{"base_hash" => doc.hash, "payload" => bad})
    end

    test "another user's document or a publication is forbidden", %{user: user} do
      doc = create(user)
      {:ok, other} = Accounts.get_or_create_user("upload-intruder@example.com")

      assert {:error, %{code: "forbidden"}} =
               upload(other, "update", doc.doc_id, %{
                 "base_hash" => doc.hash,
                 "payload" => title_patch("x")
               })

      pub =
        Repo.insert!(%Document{
          id: Ecto.UUID.generate(),
          content: %{"title" => "P"},
          content_hash: "h",
          read_only: true
        })

      assert {:error, %{code: "forbidden"}} =
               upload(user, "update", pub.id, %{"base_hash" => "h", "payload" => title_patch("x")})
    end

    test "a deleted or unknown document is not_found", %{user: user} do
      doc = create(user)
      {:ok, _} = upload(user, "delete", doc.doc_id)

      assert {:error, %{code: "not_found"}} =
               upload(user, "update", doc.doc_id, %{
                 "base_hash" => doc.hash,
                 "payload" => title_patch("x")
               })

      assert {:error, %{code: "not_found"}} =
               upload(user, "update", Ecto.UUID.generate(), %{"base_hash" => "h", "payload" => []})
    end
  end

  describe "delete" do
    test "soft-deletes and records a delete event", %{user: user} do
      doc = create(user)
      p = params("delete", doc.doc_id, %{"payload" => nil})
      assert {:ok, %{doc_id: id, seq: seq}} = Upload.run(user.id, @client_id, p)
      assert id == doc.doc_id
      assert Repo.get(Document, doc.doc_id).deleted_at
      assert %{kind: "delete", seq: ^seq} = List.last(events(doc.doc_id))
    end

    test "a never-synced or already-deleted document is not_found and writes nothing", %{
      user: user
    } do
      unknown = Ecto.UUID.generate()

      assert {:error, %{code: "not_found", is_fatal: false, doc_id: ^unknown}} =
               upload(user, "delete", unknown)

      assert events(unknown) == []

      doc = create(user)
      {:ok, _} = upload(user, "delete", doc.doc_id)
      assert {:error, %{code: "not_found"}} = upload(user, "delete", doc.doc_id)
      assert length(events(doc.doc_id)) == 2
    end

    test "a retried delete returns the stored success", %{user: user} do
      doc = create(user)
      p = params("delete", doc.doc_id)
      {:ok, first} = Upload.run(user.id, @client_id, p)
      {:ok, again} = Upload.run(user.id, @client_id, p)
      assert json(again) == json(first)
    end
  end

  describe "validation" do
    test "malformed requests", %{user: user} do
      assert {:error, %{code: "validation"}} =
               Upload.run(user.id, nil, %{"doc_id" => Ecto.UUID.generate(), "kind" => "create"})

      assert {:error, %{code: "validation"}} =
               upload(user, "create", "not-a-uuid", %{"payload" => %{}})

      assert {:error, %{code: "validation"}} = upload(user, "rename", Ecto.UUID.generate())

      assert {:error, %{code: "validation"}} =
               upload(user, "create", Ecto.UUID.generate(), %{"payload" => [1]})
    end

    test "an oversized payload is too_large", %{user: user} do
      big = %{"blob" => String.duplicate("a", 1_048_577)}

      assert {:error, %{code: "too_large", is_fatal: false}} =
               upload(user, "create", Ecto.UUID.generate(), %{"payload" => big})
    end

    test "a non-map top-level params value is validation, never a raise", %{user: user} do
      assert {:error, %{code: "validation", is_fatal: false, doc_id: nil}} =
               Upload.run(user.id, @client_id, ["not", "a", "map"])

      assert {:error, %{code: "validation", is_fatal: false, doc_id: nil}} =
               Upload.run(user.id, @client_id, "just a string")
    end

    test "a non-string doc_id is validation and is not echoed back", %{user: user} do
      assert {:error, %{code: "validation", is_fatal: false, doc_id: nil}} =
               Upload.run(user.id, @client_id, %{
                 "upload_id" => Ecto.UUID.generate(),
                 "doc_id" => 123,
                 "kind" => "create",
                 "payload" => %{}
               })
    end

    test "a malformed but string doc_id is still echoed back", %{user: user} do
      assert {:error, %{code: "validation", doc_id: "not-a-uuid"}} =
               upload(user, "create", "not-a-uuid", %{"payload" => %{}})
    end
  end

  describe "dedup keyed on doc_id" do
    test "a stored (upload_id, base_hash) under a different doc_id is validation, not the other doc's reply",
         %{user: user} do
      upload_id = Ecto.UUID.generate()

      {:ok, _first} =
        Upload.run(user.id, @client_id, %{
          "upload_id" => upload_id,
          "doc_id" => Ecto.UUID.generate(),
          "kind" => "create",
          "payload" => %{"title" => "A"}
        })

      other_doc_id = Ecto.UUID.generate()

      assert {:error, %{code: "validation", is_fatal: false, doc_id: ^other_doc_id}} =
               Upload.run(user.id, @client_id, %{
                 "upload_id" => upload_id,
                 "doc_id" => other_doc_id,
                 "kind" => "create",
                 "payload" => %{"title" => "B"}
               })

      refute Repo.get(Document, other_doc_id)
      assert events(other_doc_id) == []
    end
  end

  describe "concurrent uploads (real transactions)" do
    setup do
      {user, doc} =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, user} =
            Accounts.get_or_create_user("race-#{System.unique_integer([:positive])}@example.com")

          {:ok, doc} =
            Documents.create_document(user.id, %{id: Ecto.UUID.generate(), content: %{"n" => 0}})

          {user, doc}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from e in ChangeEvent, where: e.doc_id == ^doc.id)
          Repo.delete_all(from u in UploadResult, where: u.doc_id == ^doc.id)
          Repo.delete_all(from u in User, where: u.id == ^user.id)
        end)
      end)

      %{racer: user, doc: doc}
    end

    test "two uploads on one base: one applies, the other gets hash_mismatch; seqs chain", %{
      racer: user,
      doc: doc
    } do
      race = fn n ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Upload.run(user.id, nil, %{
              "upload_id" => Ecto.UUID.generate(),
              "doc_id" => doc.id,
              "kind" => "update",
              "base_hash" => doc.content_hash,
              "payload" => [%{"op" => "replace", "path" => "/n", "value" => n}]
            })
          end)
        end)
      end

      results = Task.await_many([race.(1), race.(2)])
      assert results |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [:error, :ok]
      assert {:error, %{code: "hash_mismatch"}} = Enum.find(results, &match?({:error, _}, &1))

      events = Sandbox.unboxed_run(Repo, fn -> events(doc.id) end)
      assert [create, update] = events
      assert update.prev_seq == create.seq
    end

    test "two concurrent creates with the same upload_id and doc_id: one writes, both get the identical reply" do
      {user, doc_id, upload_id} =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, u} =
            Accounts.get_or_create_user(
              "race-create-#{System.unique_integer([:positive])}@example.com"
            )

          {u, Ecto.UUID.generate(), Ecto.UUID.generate()}
        end)

      p = %{
        "upload_id" => upload_id,
        "doc_id" => doc_id,
        "kind" => "create",
        "payload" => %{"title" => "Race"}
      }

      race = fn ->
        Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> Upload.run(user.id, nil, p) end) end)
      end

      [r1, r2] = Task.await_many([race.(), race.()])
      assert {:ok, reply1} = r1
      assert {:ok, reply2} = r2
      assert json(reply1) == json(reply2)
      assert Sandbox.unboxed_run(Repo, fn -> length(events(doc_id)) end) == 1

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from e in ChangeEvent, where: e.doc_id == ^doc_id)
          Repo.delete_all(from ur in UploadResult, where: ur.doc_id == ^doc_id)
          Repo.delete_all(from u in User, where: u.id == ^user.id)
        end)
      end)
    end

    test "two concurrent updates with the same upload_id and base_hash: one writes, both get the identical reply",
         %{racer: user, doc: doc} do
      p = %{
        "upload_id" => Ecto.UUID.generate(),
        "doc_id" => doc.id,
        "kind" => "update",
        "base_hash" => doc.content_hash,
        "payload" => [%{"op" => "replace", "path" => "/n", "value" => 9}]
      }

      race = fn ->
        Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> Upload.run(user.id, nil, p) end) end)
      end

      [r1, r2] = Task.await_many([race.(), race.()])
      assert {:ok, reply1} = r1
      assert {:ok, reply2} = r2
      assert json(reply1) == json(reply2)
      assert Sandbox.unboxed_run(Repo, fn -> length(events(doc.id)) end) == 2
    end

    test "two concurrent updates on different doc_ids sharing an upload_id and base_hash: no crash, one wins",
         %{racer: user, doc: doc_a} do
      doc_b =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, d} =
            Documents.create_document(user.id, %{id: Ecto.UUID.generate(), content: %{"n" => 0}})

          d
        end)

      upload_id = Ecto.UUID.generate()

      race = fn doc ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Upload.run(user.id, nil, %{
              "upload_id" => upload_id,
              "doc_id" => doc.id,
              "kind" => "update",
              "base_hash" => doc.content_hash,
              "payload" => [%{"op" => "replace", "path" => "/n", "value" => 1}]
            })
          end)
        end)
      end

      results = Task.await_many([race.(doc_a), race.(doc_b)])

      assert Enum.all?(results, fn
               {:ok, _} -> true
               {:error, %{code: "validation", is_fatal: false}} -> true
               _ -> false
             end)

      outcomes = Enum.map(results, &elem(&1, 0))
      assert :ok in outcomes
      assert :error in outcomes

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from e in ChangeEvent, where: e.doc_id == ^doc_b.id)
          Repo.delete_all(from ur in UploadResult, where: ur.doc_id == ^doc_b.id)
        end)
      end)
    end
  end
end
