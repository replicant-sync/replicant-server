defmodule ReplicantServer.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "documents" do
    field :content, :map
    field :sync_revision, :integer, default: 1
    field :content_hash, :string
    field :title, :string
    field :size_bytes, :integer
    field :deleted_at, :utc_datetime_usec

    belongs_to :user, ReplicantServer.Accounts.User

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:id, :user_id, :content, :sync_revision, :content_hash, :title, :size_bytes, :deleted_at])
    |> validate_required([:id, :user_id, :content])
    |> foreign_key_constraint(:user_id)
  end

  def create_changeset(document, attrs) do
    document
    |> cast(attrs, [:id, :user_id, :content, :content_hash, :title, :size_bytes])
    |> validate_required([:id, :user_id, :content])
    |> put_change(:sync_revision, 1)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:id, name: :documents_pkey)
  end
end
