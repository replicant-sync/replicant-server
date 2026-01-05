defmodule ReplicantServer.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :last_seen_at, :utc_datetime_usec

    has_many :documents, ReplicantServer.Documents.Document

    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:id, :email, :last_seen_at])
    |> validate_required([:id, :email])
    |> unique_constraint(:email)
  end
end
