defmodule ReplicantServer.Sync.Upload do
  @moduledoc """
  The `upload` RPC: create, update or delete one source document. A success is
  stored under `(upload_id, base_hash)` and returned as-is when the same pair
  is retried; the same `upload_id` with another `base_hash` is processed anew.
  """

  alias ReplicantServer.{Documents, Feed, Repo, Scopes}
  alias ReplicantServer.Feed.UploadResult
  alias ReplicantServer.Sync.Envelope

  @max_payload_bytes 1_048_576

  def run(user_id, client_id, params) do
    case parse(params) do
      {:ok, req} -> apply_request(user_id, client_id, req)
      {:error, reason} -> {:error, error_reply({:error, reason}, params["doc_id"])}
    end
  end

  defp apply_request(user_id, client_id, req) do
    meta = %{client_id: client_id, upload_id: req.upload_id}

    Repo.transaction(fn ->
      serialize(user_id, req)

      case Repo.get_by(UploadResult, upload_id: req.upload_id, base_hash: req.base_key) do
        %UploadResult{reply: reply} -> {:stored, reply}
        nil -> write(user_id, req, meta)
      end
    end)
    |> case do
      {:ok, {:stored, reply}} ->
        {:ok, reply}

      {:ok, {:applied, doc, events}} ->
        Feed.broadcast(events, doc)
        {:ok, Envelope.doc(doc)}

      {:error, error} ->
        {:error, error_reply(error, req.doc_id)}
    end
  end

  # Takes the first lock the write itself takes, so a retry of this upload
  # waits for the original to commit before the dedup lookup.
  defp serialize(user_id, %{kind: "create"}), do: Feed.lock_scopes([Scopes.own(user_id)])
  defp serialize(_user_id, %{doc_id: doc_id}), do: Documents.lock_document(doc_id)

  defp write(user_id, req, meta) do
    result =
      case req.kind do
        "create" -> Documents.do_create(user_id, %{id: req.doc_id, content: req.payload}, meta)
        "update" -> Documents.do_update(user_id, req.doc_id, req.payload, req.base_hash, meta)
        "delete" -> Documents.do_delete(user_id, req.doc_id, meta)
      end

    case result do
      {:ok, doc, events} ->
        Repo.insert!(%UploadResult{
          upload_id: req.upload_id,
          base_hash: req.base_key,
          doc_id: doc.id,
          reply: Envelope.doc(doc)
        })

        {:applied, doc, events}

      error ->
        Repo.rollback(error)
    end
  end

  defp parse(%{"upload_id" => upload_id, "doc_id" => doc_id, "kind" => kind} = params)
       when kind in ~w(create update delete) do
    with {:ok, upload_id} <- Ecto.UUID.cast(upload_id),
         {:ok, doc_id} <- Ecto.UUID.cast(doc_id),
         :ok <- check_payload(kind, params["payload"], params["base_hash"]) do
      base_hash = if kind == "update", do: params["base_hash"]

      {:ok,
       %{
         upload_id: upload_id,
         doc_id: doc_id,
         kind: kind,
         base_hash: base_hash,
         base_key: base_hash || "",
         payload: params["payload"]
       }}
    else
      :error -> {:error, :validation}
      {:error, _reason} = error -> error
    end
  end

  defp parse(_params), do: {:error, :validation}

  defp check_payload("create", content, _base) when is_map(content), do: check_size(content)

  defp check_payload("update", patch, base) when is_list(patch) and is_binary(base),
    do: check_size(patch)

  defp check_payload("delete", _payload, _base), do: :ok
  defp check_payload(_kind, _payload, _base), do: {:error, :validation}

  defp check_size(payload) do
    if byte_size(Jason.encode!(payload)) > @max_payload_bytes, do: {:error, :too_large}, else: :ok
  end

  defp error_reply(error, doc_id) do
    {code, extra} =
      case error do
        {:error, :conflict, existing} ->
          {"exists", %{existing_owner: existing.user_id}}

        {:error, :hash_mismatch, doc} ->
          {"hash_mismatch", %{current_hash: doc.content_hash, current_seq: doc.seq}}

        {:error, :not_found} ->
          {"not_found", %{}}

        {:error, :forbidden} ->
          {"forbidden", %{}}

        {:error, :too_large} ->
          {"too_large", %{}}

        {:error, reason}
        when reason in [
               :validation,
               :invalid_patch,
               :missing_hash,
               :insert_failed,
               :update_failed
             ] ->
          {"validation", %{}}

        _other ->
          {"internal", %{}}
      end

    Envelope.error(code, Map.put(extra, :doc_id, doc_id))
  end
end
