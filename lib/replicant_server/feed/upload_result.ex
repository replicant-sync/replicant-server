defmodule ReplicantServer.Feed.UploadResult do
  @moduledoc "Stored success reply of an upload, keyed by (upload_id, base_hash); base_hash is \"\" for create and delete."
  use Ecto.Schema

  @primary_key false
  schema "upload_results" do
    field :upload_id, :binary_id, primary_key: true
    field :base_hash, :string, primary_key: true
    field :doc_id, :binary_id
    field :reply, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
