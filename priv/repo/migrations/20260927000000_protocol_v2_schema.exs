defmodule ReplicantServer.Repo.Migrations.ProtocolV2Schema do
  use Ecto.Migration

  def up do
    rename table(:change_events), to: table(:change_events_v1)

    execute "ALTER TABLE change_events_v1 RENAME CONSTRAINT change_events_pkey TO change_events_v1_pkey"

    execute "CREATE SEQUENCE change_seq AS bigint"

    create table(:change_events, primary_key: false) do
      add :scope, :text, primary_key: true
      add :seq, :bigint, primary_key: true
      add :prev_seq, :bigint, null: false
      add :doc_id, :binary_id, null: false
      add :kind, :text, null: false
      add :hash, :text
      add :client_id, :binary_id
      add :upload_id, :binary_id
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:change_events, :change_events_kind,
             check: "kind IN ('upsert', 'delete', 'leave')"
           )

    create index(:change_events, [:seq])
    create index(:change_events, [:doc_id])
    create index(:change_events, [:inserted_at])

    alter table(:documents) do
      add :seq, :bigint, null: false, default: 0
      add :read_only, :boolean, null: false, default: false
      add :author_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :source_doc_id, :binary_id
      add :source_revision, :bigint
      add :derived_from, :binary_id
    end

    create index(:documents, [:author_id])
    create index(:documents, [:source_doc_id])

    create table(:collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :access, :text, null: false, default: "private"

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:collections, [:name])
    create constraint(:collections, :collections_access, check: "access IN ('public', 'private')")

    create table(:collection_members, primary_key: false) do
      add :collection_id, references(:collections, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :added_seq, :bigint, null: false
    end

    create index(:collection_members, [:document_id])

    execute """
    INSERT INTO collections (id, name, access, created_at, updated_at)
    VALUES (gen_random_uuid(), 'curated', 'public', now(), now())
    """

    create table(:upload_results, primary_key: false) do
      add :upload_id, :binary_id, primary_key: true
      add :base_hash, :text, primary_key: true
      add :doc_id, :binary_id, null: false
      add :reply, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:upload_results, [:inserted_at])

    create table(:change_feed_state, primary_key: false) do
      add :id, :integer, primary_key: true
      add :trim_watermark, :bigint, null: false, default: 0
    end

    execute "INSERT INTO change_feed_state (id, trim_watermark) VALUES (1, 0)"
  end

  def down do
    drop table(:change_feed_state)
    drop table(:upload_results)
    drop table(:collection_members)
    drop table(:collections)

    alter table(:documents) do
      remove :seq
      remove :read_only
      remove :author_id
      remove :source_doc_id
      remove :source_revision
      remove :derived_from
    end

    drop table(:change_events)
    execute "DROP SEQUENCE change_seq"
    rename table(:change_events_v1), to: table(:change_events)

    execute "ALTER TABLE change_events RENAME CONSTRAINT change_events_v1_pkey TO change_events_pkey"
  end
end
