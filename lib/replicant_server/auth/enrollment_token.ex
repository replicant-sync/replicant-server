defmodule ReplicantServer.Auth.EnrollmentToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "enrollment_tokens" do
    field :token_hash, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    belongs_to :user, ReplicantServer.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :expires_at, :used_at, :user_id])
    |> validate_required([:token_hash, :expires_at, :user_id])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end
end
