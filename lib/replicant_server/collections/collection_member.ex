defmodule ReplicantServer.Collections.CollectionMember do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "collection_members" do
    belongs_to :collection, ReplicantServer.Collections.Collection, primary_key: true
    belongs_to :document, ReplicantServer.Documents.Document, primary_key: true
    field :added_seq, :integer
  end
end
