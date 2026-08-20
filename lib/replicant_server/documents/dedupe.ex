defmodule ReplicantServer.Documents.Dedupe do
  @moduledoc """
  Finds and removes duplicate per-user documents (see DEV-1010).

  Two grouping passes, both scoped to live, per-user (non-public) documents:

    * hash pass (always on) — groups byte-identical content by `content_hash`
    * semantic pass (opt-in) — additionally groups `type == "tuning"` documents
      by musical identity (`title`, `period`, `pitches`), catching duplicates
      that serialize differently but represent the same tuning

  Within each group the oldest document (by `created_at`, tie-broken by `id`)
  is kept; the rest are soft-deleted via `Documents.delete_document/2` so
  sync tombstones are produced normally. Re-running finds nothing once
  duplicates are gone.
  """

  import Ecto.Query

  alias ReplicantServer.Accounts
  alias ReplicantServer.Accounts.User
  alias ReplicantServer.Documents
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Repo

  defmodule Group do
    @moduledoc false
    defstruct [:user_id, :user_email, :pass, :kept, :to_delete]
  end

  @doc """
  Runs the dedupe scan (and, if `execute: true`, applies it).

  Options: `execute` (default `false`), `semantic` (default `false`),
  `user` (id or email, restricts to one user).

  Returns `{:ok, report}` or `{:error, :user_not_found}`.
  """
  def run(opts \\ []) do
    execute? = Keyword.get(opts, :execute, false)
    semantic? = Keyword.get(opts, :semantic, false)

    with {:ok, users} <- resolve_users(Keyword.get(opts, :user)) do
      groups = Enum.flat_map(users, &groups_for_user(&1, semantic?))

      if execute?, do: Enum.each(groups, &apply_group/1)

      {:ok,
       %{
         execute: execute?,
         semantic: semantic?,
         users_scanned: length(users),
         groups: groups,
         hash_groups: Enum.count(groups, &(&1.pass == :hash)),
         semantic_groups: Enum.count(groups, &(&1.pass == :semantic)),
         affected_count: groups |> Enum.map(&length(&1.to_delete)) |> Enum.sum()
       }}
    end
  end

  defp apply_group(%Group{user_id: user_id, to_delete: to_delete}) do
    Enum.each(to_delete, fn doc ->
      {:ok, _} = Documents.delete_document(user_id, doc.id)
    end)
  end

  defp resolve_users(nil) do
    user_ids =
      Repo.all(
        from d in Document,
          where: not is_nil(d.user_id) and d.visibility != "public" and is_nil(d.deleted_at),
          distinct: true,
          select: d.user_id
      )

    {:ok, Repo.all(from u in User, where: u.id in ^user_ids)}
  end

  defp resolve_users(ref) do
    user =
      case Ecto.UUID.cast(ref) do
        {:ok, id} -> Accounts.get_user(id)
        :error -> Accounts.get_user_by_email(ref)
      end

    case user do
      nil -> {:error, :user_not_found}
      %User{} = user -> {:ok, [user]}
    end
  end

  defp groups_for_user(%User{} = user, semantic?) do
    docs =
      Repo.all(
        from d in Document,
          where: d.user_id == ^user.id and is_nil(d.deleted_at) and d.visibility != "public",
          order_by: [asc: d.created_at, asc: d.id]
      )

    hash_groups =
      docs
      |> Enum.filter(&(&1.content_hash != nil))
      |> Enum.group_by(& &1.content_hash)
      |> Enum.filter(fn {_hash, group} -> length(group) > 1 end)

    hash_deleted_ids =
      hash_groups
      |> Enum.flat_map(fn {_hash, [_keep | rest]} -> rest end)
      |> MapSet.new(& &1.id)

    hash_result =
      for {_hash, [keep | rest]} <- hash_groups,
          do: build_group(user, :hash, keep, rest)

    semantic_result =
      if semantic? do
        docs
        |> Enum.reject(&(&1.id in hash_deleted_ids))
        |> Enum.filter(&tuning?/1)
        |> Enum.group_by(&semantic_key/1)
        |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
        |> Enum.map(fn {_key, [keep | rest]} -> build_group(user, :semantic, keep, rest) end)
      else
        []
      end

    hash_result ++ semantic_result
  end

  defp build_group(%User{} = user, pass, keep, rest) do
    %Group{user_id: user.id, user_email: user.email, pass: pass, kept: keep, to_delete: rest}
  end

  defp tuning?(%Document{content: %{"type" => "tuning"}}), do: true
  defp tuning?(_), do: false

  defp semantic_key(%Document{content: content}) do
    {content["title"], content["period"], content["pitches"]}
  end
end
