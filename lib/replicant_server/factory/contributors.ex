defmodule ReplicantServer.Factory.Contributors do
  @moduledoc """
  Loads the (git-ignored) factory-contributor config and resolves each preset's
  author to the user that should own it. Overrides win over the preset's
  `content["author"]`; an empty author with no override falls back to the
  system user.
  """

  @doc "Evaluate a `factory_contributors.exs` config file into a map."
  def load(path) do
    if File.exists?(path) do
      {config, _bindings} = Code.eval_file(path)
      {:ok, config}
    else
      {:error, {:missing_config, path}}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Resolve the owner for a preset. `author` is the preset's `content["author"]`;
  `slug` is the JSON filename without extension. Returns the `%{email, display_name}`
  to mint, applying `overrides` first, then the named contributor, then `system`.
  """
  def resolve(config, author, slug) do
    cond do
      Map.has_key?(config.overrides, slug) ->
        name = config.overrides[slug]
        fetch_contributor(config, name)

      is_binary(author) and String.trim(author) != "" and Map.has_key?(config.contributors, author) ->
        fetch_contributor(config, author)

      true ->
        {:ok, config.system}
    end
  end

  defp fetch_contributor(config, name) do
    case Map.fetch(config.contributors, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_contributor, name}}
    end
  end
end
