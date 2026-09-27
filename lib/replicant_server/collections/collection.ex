defmodule ReplicantServer.Collections.Collection do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "collections" do
    field :name, :string
    field :owner_id, :binary_id
    field :access, :string, default: "private"

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
