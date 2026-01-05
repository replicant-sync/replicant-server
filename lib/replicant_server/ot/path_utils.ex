defmodule ReplicantServer.OT.PathUtils do
  @moduledoc """
  Path manipulation utilities for JSON Pointer paths (RFC 6901).
  """

  alias ReplicantServer.OT.Types

  @doc """
  Parse JSON Pointer into segments.

  ## Examples

      iex> PathUtils.parse_path("/foo/bar")
      {:ok, %{raw: "/foo/bar", segments: [{:object, "foo"}, {:object, "bar"}]}}

      iex> PathUtils.parse_path("/items/0/name")
      {:ok, %{raw: "/items/0/name", segments: [{:object, "items"}, {:array, 0}, {:object, "name"}]}}
  """
  @spec parse_path(String.t()) :: {:ok, Types.parsed_path()} | {:error, String.t()}
  def parse_path(""), do: {:error, "Empty path"}

  def parse_path(path) do
    if not String.starts_with?(path, "/") do
      {:error, "Path must start with /: #{path}"}
    else
      if path == "/" do
        {:ok, %{raw: path, segments: []}}
      else
        segments =
          path
          |> String.slice(1..-1//1)
          |> String.split("/")
          |> Enum.map(&parse_segment/1)

        {:ok, %{raw: path, segments: segments}}
      end
    end
  end

  defp parse_segment(segment) do
    # Unescape ~1 -> / and ~0 -> ~ (order matters!)
    unescaped = segment |> String.replace("~1", "/") |> String.replace("~0", "~")

    case Integer.parse(unescaped) do
      {index, ""} when index >= 0 -> {:array, index}
      _ -> {:object, unescaped}
    end
  end

  @doc """
  Extract the last array index from a path, if present.

  ## Examples

      iex> PathUtils.extract_array_index("/items/5")
      5

      iex> PathUtils.extract_array_index("/users/0/posts/3")
      3

      iex> PathUtils.extract_array_index("/title")
      nil
  """
  @spec extract_array_index(String.t()) :: non_neg_integer() | nil
  def extract_array_index(path) do
    case parse_path(path) do
      {:ok, %{segments: segments}} ->
        segments
        |> Enum.reverse()
        |> Enum.find_value(fn
          {:array, idx} -> idx
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  @doc """
  Adjust array index in path by delta.

  Only adjusts if the current index matches target_index.

  ## Examples

      iex> PathUtils.adjust_array_index("/items/5", 5, 1)
      {:ok, "/items/6"}

      iex> PathUtils.adjust_array_index("/items/5", 3, 1)
      {:ok, "/items/5"}  # No change - index doesn't match

      iex> PathUtils.adjust_array_index("/items/2", 2, -3)
      {:error, "Index adjustment would be negative: 2 + -3 = -1"}
  """
  @spec adjust_array_index(String.t(), non_neg_integer(), integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def adjust_array_index(path, target_index, delta) do
    case parse_path(path) do
      {:ok, %{segments: segments}} ->
        # Find last array index that matches target
        idx_position =
          segments
          |> Enum.with_index()
          |> Enum.reverse()
          |> Enum.find_value(fn
            {{:array, idx}, pos} when idx == target_index -> pos
            _ -> nil
          end)

        if idx_position do
          new_index = target_index + delta

          if new_index < 0 do
            {:error,
             "Index adjustment would be negative: #{target_index} + #{delta} = #{new_index}"}
          else
            new_segments = List.replace_at(segments, idx_position, {:array, new_index})
            {:ok, reconstruct_path(new_segments)}
          end
        else
          {:ok, path}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Reconstruct path from segments.
  """
  @spec reconstruct_path([Types.path_segment()]) :: String.t()
  def reconstruct_path([]), do: "/"

  def reconstruct_path(segments) do
    segments
    |> Enum.map(fn
      {:object, key} ->
        # Re-escape special characters (~ must be escaped before /)
        escaped = key |> String.replace("~", "~0") |> String.replace("/", "~1")
        "/" <> escaped

      {:array, idx} ->
        "/" <> Integer.to_string(idx)
    end)
    |> Enum.join()
  end

  @doc """
  Determine relationship between two paths.

  ## Examples

      iex> PathUtils.compare_paths("/a", "/a")
      :same

      iex> PathUtils.compare_paths("/a", "/a/b")
      :parent

      iex> PathUtils.compare_paths("/a/b", "/a/c")
      :sibling
  """
  @spec compare_paths(String.t(), String.t()) :: Types.path_relation()
  def compare_paths(path1, path2) when path1 == path2, do: :same

  def compare_paths(path1, path2) do
    cond do
      String.starts_with?(path2, path1 <> "/") ->
        :parent

      String.starts_with?(path1, path2 <> "/") ->
        :child

      true ->
        parent1 = get_parent_path(path1)
        parent2 = get_parent_path(path2)

        if parent1 != nil and parent1 == parent2 do
          :sibling
        else
          :unrelated
        end
    end
  end

  @doc """
  Get parent path, or nil if root.

  ## Examples

      iex> PathUtils.get_parent_path("/a/b/c")
      "/a/b"

      iex> PathUtils.get_parent_path("/a")
      "/"

      iex> PathUtils.get_parent_path("/")
      nil
  """
  @spec get_parent_path(String.t()) :: String.t() | nil
  def get_parent_path("/"), do: nil

  def get_parent_path(path) do
    # Find last occurrence of /
    case String.split(path, "/") |> Enum.drop(-1) |> Enum.join("/") do
      "" -> "/"
      parent -> parent
    end
  end

  @doc """
  Check if two paths conflict (one would affect the other).

  Conflicts occur when:
  - Same path
  - Parent-child relationship (modifying parent affects child)

  ## Examples

      iex> PathUtils.paths_conflict("/a", "/a")
      true

      iex> PathUtils.paths_conflict("/a", "/a/b")
      true

      iex> PathUtils.paths_conflict("/a", "/b")
      false
  """
  @spec paths_conflict(String.t(), String.t()) :: boolean()
  def paths_conflict(path1, path2) do
    compare_paths(path1, path2) in [:same, :parent, :child]
  end
end
