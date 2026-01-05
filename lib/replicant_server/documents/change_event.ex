defmodule ReplicantServer.Documents.ChangeEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias ReplicantServer.Ecto.JsonValue

  @primary_key {:sequence, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_events" do
    field :event_type, :string
    field :forward_patch, JsonValue
    field :reverse_patch, JsonValue
    field :applied, :boolean, default: true
    field :server_timestamp, :utc_datetime_usec

    belongs_to :document, ReplicantServer.Documents.Document, type: :binary_id
    belongs_to :user, ReplicantServer.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end

  @event_types ~w(create update delete)

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:document_id, :user_id, :event_type, :forward_patch, :reverse_patch, :applied, :server_timestamp])
    |> validate_required([:document_id, :user_id, :event_type])
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:user_id)
    |> put_server_timestamp()
  end

  defp put_server_timestamp(changeset) do
    if get_field(changeset, :server_timestamp) do
      changeset
    else
      put_change(changeset, :server_timestamp, DateTime.utc_now())
    end
  end
end
