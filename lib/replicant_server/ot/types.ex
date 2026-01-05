defmodule ReplicantServer.OT.Types do
  @moduledoc """
  Core types for Operational Transformation on JSON Patch operations.
  """

  @type path_relation :: :same | :parent | :child | :sibling | :unrelated

  @type path_segment :: {:object, String.t()} | {:array, non_neg_integer()}

  @type parsed_path :: %{
          raw: String.t(),
          segments: [path_segment()]
        }
end
