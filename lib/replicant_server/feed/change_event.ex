defmodule ReplicantServer.Feed.ChangeEvent do
  @moduledoc "One row per (scope, logical change). Rows are only deleted by retention."
  use Ecto.Schema

  @primary_key false
  schema "change_events" do
    field :scope, :string, primary_key: true
    field :seq, :integer, primary_key: true
    field :prev_seq, :integer
    field :doc_id, :binary_id
    field :kind, :string
    field :hash, :string
    field :client_id, :binary_id
    field :upload_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
