defmodule ReplicantServer.Ecto.JsonValue do
  @moduledoc """
  Custom Ecto type that accepts any JSON-encodable value (maps, lists, etc.)
  for use with PostgreSQL JSONB columns.
  """
  use Ecto.Type

  def type, do: :map

  def cast(value) when is_map(value) or is_list(value) or is_nil(value), do: {:ok, value}
  def cast(_), do: :error

  def load(value), do: {:ok, value}

  def dump(value) when is_map(value) or is_list(value) or is_nil(value), do: {:ok, value}
  def dump(_), do: :error
end
