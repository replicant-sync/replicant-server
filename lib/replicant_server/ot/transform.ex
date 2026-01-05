defmodule ReplicantServer.OT.Transform do
  @moduledoc """
  Operational transformation functions for JSON Patch operations.

  Handles array index adjustments and conflict detection for concurrent operations.
  """

  alias ReplicantServer.OT.PathUtils

  @type patch_op :: %{
          op: String.t(),
          path: String.t(),
          value: term(),
          from: String.t() | nil
        }

  # ============================================================================
  # Add vs Add Transformation
  # ============================================================================

  @doc """
  Transform two Add operations.

  Returns {local_transformed, remote_transformed}.
  """
  @spec transform_add_add(patch_op(), patch_op()) ::
          {:ok, {patch_op() | nil, patch_op() | nil}} | {:error, String.t()}
  def transform_add_add(local, remote) do
    local_idx = PathUtils.extract_array_index(local.path)
    remote_idx = PathUtils.extract_array_index(remote.path)

    if local_idx != nil and remote_idx != nil do
      # Check if same array
      if PathUtils.get_parent_path(local.path) == PathUtils.get_parent_path(remote.path) do
        # Both adding to same array - adjust indices
        if local_idx <= remote_idx do
          # Local goes first, adjust remote up
          case PathUtils.adjust_array_index(remote.path, remote_idx, 1) do
            {:ok, adjusted_path} ->
              {:ok, {local, %{remote | path: adjusted_path}}}

            {:error, _} = error ->
              error
          end
        else
          # Remote goes first, adjust local up
          case PathUtils.adjust_array_index(local.path, local_idx, 1) do
            {:ok, adjusted_path} ->
              {:ok, {%{local | path: adjusted_path}, remote}}

            {:error, _} = error ->
              error
          end
        end
      else
        # Different arrays
        {:ok, {local, remote}}
      end
    else
      # Not array operations - return both (caller handles conflicts)
      {:ok, {local, remote}}
    end
  end

  # ============================================================================
  # Remove vs Remove Transformation
  # ============================================================================

  @doc """
  Transform two Remove operations.

  Returns {local_transformed, remote_transformed}.
  """
  @spec transform_remove_remove(patch_op(), patch_op()) ::
          {:ok, {patch_op() | nil, patch_op() | nil}} | {:error, String.t()}
  def transform_remove_remove(local, remote) do
    local_idx = PathUtils.extract_array_index(local.path)
    remote_idx = PathUtils.extract_array_index(remote.path)

    if local_idx != nil and remote_idx != nil do
      if PathUtils.get_parent_path(local.path) == PathUtils.get_parent_path(remote.path) do
        # Same array
        cond do
          local_idx < remote_idx ->
            # Local removes first, remote index shifts down
            case PathUtils.adjust_array_index(remote.path, remote_idx, -1) do
              {:ok, adjusted_path} ->
                {:ok, {local, %{remote | path: adjusted_path}}}

              {:error, _} = error ->
                error
            end

          local_idx > remote_idx ->
            # Remote removes first, local index shifts down
            case PathUtils.adjust_array_index(local.path, local_idx, -1) do
              {:ok, adjusted_path} ->
                {:ok, {%{local | path: adjusted_path}, remote}}

              {:error, _} = error ->
                error
            end

          true ->
            # Same index - conflict
            {:ok, {local, remote}}
        end
      else
        # Different arrays
        {:ok, {local, remote}}
      end
    else
      # Not array operations
      {:ok, {local, remote}}
    end
  end

  # ============================================================================
  # Add vs Remove Transformation
  # ============================================================================

  @doc """
  Transform Add and Remove operations.

  Returns {add_transformed, remove_transformed}.
  """
  @spec transform_add_remove(patch_op(), patch_op()) ::
          {:ok, {patch_op() | nil, patch_op() | nil}} | {:error, String.t()}
  def transform_add_remove(add, remove) do
    add_idx = PathUtils.extract_array_index(add.path)
    rem_idx = PathUtils.extract_array_index(remove.path)

    if add_idx != nil and rem_idx != nil do
      if PathUtils.get_parent_path(add.path) == PathUtils.get_parent_path(remove.path) do
        # Same array
        if add_idx <= rem_idx do
          # Add happens first, remove index shifts up
          case PathUtils.adjust_array_index(remove.path, rem_idx, 1) do
            {:ok, adjusted_path} ->
              {:ok, {add, %{remove | path: adjusted_path}}}

            {:error, _} = error ->
              error
          end
        else
          # Remove happens first, add index shifts down
          case PathUtils.adjust_array_index(add.path, add_idx, -1) do
            {:ok, adjusted_path} ->
              {:ok, {%{add | path: adjusted_path}, remove}}

            {:error, _} = error ->
              error
          end
        end
      else
        # Different arrays
        {:ok, {add, remove}}
      end
    else
      # Not array operations
      {:ok, {add, remove}}
    end
  end

  # ============================================================================
  # Replace Operations
  # ============================================================================

  @doc """
  Transform two Replace operations.

  Returns {local_transformed, remote_transformed}.
  """
  @spec transform_replace_replace(patch_op(), patch_op()) ::
          {:ok, {patch_op() | nil, patch_op() | nil}}
  def transform_replace_replace(local, remote) do
    # Replace operations don't affect each other unless same path (conflict)
    {:ok, {local, remote}}
  end

  # ============================================================================
  # Main Transform Function
  # ============================================================================

  @doc """
  Transform two patch operations.

  Handles: add, remove, replace with array index adjustments.
  Returns {local_transformed, remote_transformed}.

  ## Examples

      iex> local = %{op: "add", path: "/items/2", value: "local"}
      iex> remote = %{op: "add", path: "/items/5", value: "remote"}
      iex> Transform.transform_operation_pair(local, remote)
      {:ok, {%{op: "add", path: "/items/2", value: "local"},
             %{op: "add", path: "/items/6", value: "remote"}}}
  """
  @spec transform_operation_pair(patch_op(), patch_op()) ::
          {:ok, {patch_op() | nil, patch_op() | nil}} | {:error, String.t()}
  def transform_operation_pair(local, remote) do
    case {local.op, remote.op} do
      {"add", "add"} ->
        transform_add_add(local, remote)

      {"remove", "remove"} ->
        transform_remove_remove(local, remote)

      {"add", "remove"} ->
        transform_add_remove(local, remote)

      {"remove", "add"} ->
        case transform_add_remove(remote, local) do
          {:ok, {add_result, remove_result}} ->
            {:ok, {remove_result, add_result}}

          error ->
            error
        end

      {"replace", "replace"} ->
        transform_replace_replace(local, remote)

      # Test operations - pass through (read-only)
      {"test", _} ->
        {:ok, {local, remote}}

      {_, "test"} ->
        {:ok, {local, remote}}

      # Move/Copy - return as-is for MVP (complex operations)
      {"move", _} ->
        {:ok, {local, remote}}

      {"copy", _} ->
        {:ok, {local, remote}}

      {_, "move"} ->
        {:ok, {local, remote}}

      {_, "copy"} ->
        {:ok, {local, remote}}

      # All other combinations
      _ ->
        {:ok, {local, remote}}
    end
  end

  @doc """
  Transform a list of local operations against a list of remote operations.

  Returns {transformed_local_ops, transformed_remote_ops}.
  """
  @spec transform_patches([patch_op()], [patch_op()]) ::
          {:ok, {[patch_op()], [patch_op()]}} | {:error, String.t()}
  def transform_patches(local_ops, remote_ops) do
    # Transform each local op against all remote ops, then vice versa
    with {:ok, transformed_local} <- transform_ops_against(local_ops, remote_ops),
         {:ok, transformed_remote} <- transform_ops_against(remote_ops, local_ops) do
      {:ok, {transformed_local, transformed_remote}}
    end
  end

  defp transform_ops_against(ops, against_ops) do
    Enum.reduce_while(ops, {:ok, []}, fn op, {:ok, acc} ->
      case transform_single_against_all(op, against_ops) do
        {:ok, transformed_op} when transformed_op != nil ->
          {:cont, {:ok, acc ++ [transformed_op]}}

        {:ok, nil} ->
          # Operation was nullified
          {:cont, {:ok, acc}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp transform_single_against_all(op, []), do: {:ok, op}

  defp transform_single_against_all(op, [against | rest]) do
    case transform_operation_pair(op, against) do
      {:ok, {transformed_op, _}} when transformed_op != nil ->
        transform_single_against_all(transformed_op, rest)

      {:ok, {nil, _}} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end
end
