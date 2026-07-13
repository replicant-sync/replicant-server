defmodule ReplicantServer.Factory.Backfill do
  @moduledoc """
  Reads a directory of canonical preset JSONs and upserts each as an owned,
  public document. Mints the resolved owner (contributor or system user) with a
  display name, stamps `author_name`, and derives a stable per-slug document id
  so re-runs update in place instead of duplicating.
  """

  import Ecto.Query

  alias ReplicantServer.{Accounts, Repo}
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

    owner_entry =
      case Contributors.resolve(config, author, slug) do
        {:ok, entry} ->
          entry

        {:error, {:unknown_contributor, name}} ->
          raise ArgumentError,
                "unknown contributor #{inspect(name)} referenced by preset #{inspect(slug)} — " <>
                  "check the contributors/overrides map in factory_contributors.exs"
      end

    owner = Map.fetch!(minted, owner_entry.display_name)

    doc_id = deterministic_doc_id(slug)

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

  @doc """
  Stable per-slug document id so backfill re-runs update in place. Reproduces
  the historical derivation (trim+downcase, uuid5 under the legacy namespace)
  byte-for-byte so existing factory documents keep their ids.
  """
  def deterministic_doc_id(slug) do
    name = (@doc_namespace <> "/" <> slug) |> String.trim() |> String.downcase()
    UUID.uuid5(UUID.uuid5(:dns, "com.nodeaudio.entonal"), name)
  end
end
