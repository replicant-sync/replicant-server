defmodule ReplicantServer.Factory.Backfill do
  @moduledoc """
  Reads a directory of canonical preset JSONs and upserts each as an owned,
  public document. Mints the resolved owner (contributor or system user) with a
  display name, stamps `author_name`, and derives a stable per-slug document id
  so re-runs update in place instead of duplicating.
  """

  import Ecto.Query

  alias ReplicantServer.{Accounts, Auth, Repo}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Factory.Contributors

  @doc_namespace "com.nodeaudio.entonal/factory-tuning"

  def run(json_dir, config) do
    files =
      json_dir
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> Enum.sort()

    minted = mint_all_users(config)

    {created, updated} =
      Enum.reduce(files, {0, 0}, fn path, {c, u} ->
        case upsert_file(path, config, minted) do
          :created -> {c + 1, u}
          :updated -> {c, u + 1}
        end
      end)

    {:ok, %{created: created, updated: updated, users: map_size(minted)}}
  end

  # Mint every user referenced by the config once, up front. Returns a map of
  # display_name => %User{}.
  defp mint_all_users(config) do
    entries =
      config.contributors
      |> Map.values()
      |> Kernel.++([config.system])
      |> Enum.uniq_by(& &1.email)

    Map.new(entries, fn %{email: email, display_name: name} ->
      {:ok, user} = Accounts.upsert_user(email, name)
      {name, user}
    end)
  end

  defp upsert_file(path, config, minted) do
    slug = Path.basename(path, ".json")
    content = path |> File.read!() |> Jason.decode!()
    author = Map.get(content, "author", "")

    {:ok, owner_entry} = Contributors.resolve(config, author, slug)
    owner = Map.fetch!(minted, owner_entry.display_name)

    doc_id = Auth.deterministic_user_id(@doc_namespace <> "/" <> slug)

    attrs = %{
      id: doc_id,
      user_id: owner.id,
      content: content,
      author_name: owner.display_name,
      visibility: "public"
    }

    case Repo.one(from d in Document, where: d.id == ^doc_id) do
      nil ->
        %Document{}
        |> Document.create_changeset(attrs)
        |> Repo.insert!()

        :created

      %Document{} = existing ->
        existing
        |> Document.changeset(attrs)
        |> Repo.update!()

        :updated
    end
  end
end
