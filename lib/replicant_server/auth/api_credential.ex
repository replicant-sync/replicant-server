defmodule ReplicantServer.Auth.ApiCredential do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_credentials" do
    field :api_key, :string
    field :secret, :string
    field :name, :string
    field :last_used_at, :utc_datetime_usec
    field :is_active, :boolean, default: true
    belongs_to :user, ReplicantServer.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:api_key, :secret, :name, :is_active, :user_id])
    |> validate_required([:api_key, :secret, :name])
    |> unique_constraint(:api_key)
    |> validate_format(:api_key, ~r/^rpa_[a-f0-9]{64}$/,
      message: "must be in format rpa_<64 hex chars>"
    )
    |> validate_format(:secret, ~r/^rps_[a-f0-9]{64}$/,
      message: "must be in format rps_<64 hex chars>"
    )
  end

  def touch_last_used_changeset(credential) do
    change(credential, last_used_at: DateTime.utc_now())
  end
end
