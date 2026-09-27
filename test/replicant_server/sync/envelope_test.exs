defmodule ReplicantServer.Sync.EnvelopeTest do
  use ExUnit.Case, async: true

  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Feed.ChangeEvent
  alias ReplicantServer.Sync.Envelope

  # Rust DocEnvelope fields (replicant-client src/engine/types.rs) plus the spec's timestamps.
  @doc_keys ~w(author_id content created_at derived_from doc_id hash owner_id read_only seq source_doc_id title updated_at)a

  defp doc do
    %Document{
      id: "d",
      user_id: "u",
      content: %{"title" => "T"},
      content_hash: "h",
      title: "T",
      seq: 7
    }
  end

  test "doc/1 carries exactly the client's DocEnvelope fields" do
    envelope = Envelope.doc(doc())
    assert envelope |> Map.keys() |> Enum.sort() == @doc_keys
    assert %{doc_id: "d", owner_id: "u", hash: "h", seq: 7, read_only: false} = envelope
  end

  test "change/3 embeds the document only for upserts" do
    event = %ChangeEvent{
      scope: "own:u",
      seq: 7,
      prev_seq: 3,
      doc_id: "d",
      kind: "upsert",
      upload_id: "m"
    }

    assert %{
             scope: "own",
             seq: 7,
             prev_seq: 3,
             kind: "upsert",
             doc: %{doc_id: "d"},
             upload_id: "m",
             client_id: nil
           } =
             Envelope.change(event, doc(), "own")

    assert %{kind: "delete", doc: nil} = Envelope.change(%{event | kind: "delete"}, doc(), "own")
    assert %{kind: "leave", doc: nil} = Envelope.change(%{event | kind: "leave"}, nil, "own")
  end

  test "error/2 marks only connection-level codes fatal" do
    assert %{code: "update_required", is_fatal: true} = Envelope.error("update_required")
    assert %{code: "auth_invalid", is_fatal: true} = Envelope.error("auth_invalid")
    assert %{code: "account_disabled", is_fatal: true} = Envelope.error("account_disabled")

    assert %{code: "forbidden", is_fatal: false, doc_id: "d"} =
             Envelope.error("forbidden", %{doc_id: "d"})

    assert %{code: "hash_mismatch", is_fatal: false} = Envelope.error("hash_mismatch")
  end
end
