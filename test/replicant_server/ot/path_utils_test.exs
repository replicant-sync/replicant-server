defmodule ReplicantServer.OT.PathUtilsTest do
  use ExUnit.Case, async: true

  alias ReplicantServer.OT.PathUtils

  describe "parse_path" do
    test "parses simple object path" do
      {:ok, path} = PathUtils.parse_path("/foo/bar")
      assert path.segments == [{:object, "foo"}, {:object, "bar"}]
    end

    test "parses array path" do
      {:ok, path} = PathUtils.parse_path("/items/0/name")

      assert path.segments == [
               {:object, "items"},
               {:array, 0},
               {:object, "name"}
             ]
    end

    test "parses root path" do
      {:ok, path} = PathUtils.parse_path("/")
      assert path.segments == []
    end

    test "parses escaped characters" do
      {:ok, path} = PathUtils.parse_path("/foo~0bar/baz~1qux")
      assert path.segments == [{:object, "foo~bar"}, {:object, "baz/qux"}]
    end

    test "rejects path without leading slash" do
      assert {:error, _} = PathUtils.parse_path("foo/bar")
    end

    test "rejects empty path" do
      assert {:error, _} = PathUtils.parse_path("")
    end
  end

  describe "extract_array_index" do
    test "extracts simple array index" do
      assert PathUtils.extract_array_index("/items/0") == 0
      assert PathUtils.extract_array_index("/items/42") == 42
      assert PathUtils.extract_array_index("/items/999") == 999
    end

    test "extracts last array index from nested path" do
      assert PathUtils.extract_array_index("/users/5/posts/3") == 3
      assert PathUtils.extract_array_index("/data/0/items/1/tags/2") == 2
    end

    test "returns nil for non-array paths" do
      assert PathUtils.extract_array_index("/title") == nil
      assert PathUtils.extract_array_index("/metadata/author") == nil
      assert PathUtils.extract_array_index("/") == nil
    end

    test "returns nil for non-numeric segments" do
      assert PathUtils.extract_array_index("/items/abc") == nil
      assert PathUtils.extract_array_index("/items/-") == nil
    end
  end

  describe "adjust_array_index" do
    test "increments index" do
      assert {:ok, "/items/6"} = PathUtils.adjust_array_index("/items/5", 5, 1)
      assert {:ok, "/items/3"} = PathUtils.adjust_array_index("/items/0", 0, 3)
    end

    test "decrements index" do
      assert {:ok, "/items/3"} = PathUtils.adjust_array_index("/items/5", 5, -2)
      assert {:ok, "/items/9"} = PathUtils.adjust_array_index("/items/10", 10, -1)
    end

    test "returns error on underflow" do
      assert {:error, _} = PathUtils.adjust_array_index("/items/2", 2, -3)
      assert {:error, _} = PathUtils.adjust_array_index("/items/0", 0, -1)
    end

    test "returns unchanged when index doesn't match" do
      assert {:ok, "/items/3"} = PathUtils.adjust_array_index("/items/3", 5, 1)
    end

    test "adjusts nested array index" do
      assert {:ok, "/data/items/6/name"} =
               PathUtils.adjust_array_index("/data/items/5/name", 5, 1)
    end

    test "returns unchanged for non-array path" do
      assert {:ok, "/title"} = PathUtils.adjust_array_index("/title", 0, 1)
    end
  end

  describe "compare_paths" do
    test "detects same paths" do
      assert PathUtils.compare_paths("/a", "/a") == :same
      assert PathUtils.compare_paths("/a/b/c", "/a/b/c") == :same
      assert PathUtils.compare_paths("/", "/") == :same
    end

    test "detects parent-child relationships" do
      assert PathUtils.compare_paths("/a", "/a/b") == :parent
      assert PathUtils.compare_paths("/a/b", "/a") == :child
      assert PathUtils.compare_paths("/items", "/items/0") == :parent
      assert PathUtils.compare_paths("/users/0/posts/1", "/users/0") == :child
    end

    test "detects siblings" do
      assert PathUtils.compare_paths("/a/b", "/a/c") == :sibling
      assert PathUtils.compare_paths("/items/0", "/items/1") == :sibling
      assert PathUtils.compare_paths("/x/y/z", "/x/y/w") == :sibling
    end

    test "detects root-level array siblings" do
      assert PathUtils.compare_paths("/0", "/1") == :sibling
      assert PathUtils.compare_paths("/0", "/2") == :sibling
      assert PathUtils.compare_paths("/10", "/20") == :sibling
    end

    test "detects root-level object siblings" do
      # Root-level paths have parent "/" so they're siblings
      assert PathUtils.compare_paths("/a", "/b") == :sibling
    end

    test "detects unrelated paths" do
      assert PathUtils.compare_paths("/users/1", "/posts/1") == :unrelated
      assert PathUtils.compare_paths("/x/y", "/a/b/c") == :unrelated
    end
  end

  describe "get_parent_path" do
    test "returns parent for nested paths" do
      assert PathUtils.get_parent_path("/a/b/c") == "/a/b"
      assert PathUtils.get_parent_path("/items/0") == "/items"
      assert PathUtils.get_parent_path("/x") == "/"
    end

    test "returns nil for root" do
      assert PathUtils.get_parent_path("/") == nil
    end
  end

  describe "paths_conflict" do
    test "same paths conflict" do
      assert PathUtils.paths_conflict("/a", "/a")
      assert PathUtils.paths_conflict("/items/0", "/items/0")
    end

    test "parent-child paths conflict" do
      assert PathUtils.paths_conflict("/a", "/a/b")
      assert PathUtils.paths_conflict("/a/b", "/a")
    end

    test "siblings don't conflict" do
      refute PathUtils.paths_conflict("/a/b", "/a/c")
      refute PathUtils.paths_conflict("/items/0", "/items/1")
    end

    test "unrelated paths don't conflict" do
      refute PathUtils.paths_conflict("/a", "/b")
      refute PathUtils.paths_conflict("/users", "/posts")
    end
  end

  describe "reconstruct_path" do
    test "reconstructs simple path" do
      segments = [{:object, "foo"}, {:object, "bar"}]
      assert PathUtils.reconstruct_path(segments) == "/foo/bar"
    end

    test "reconstructs path with array index" do
      segments = [{:object, "items"}, {:array, 5}, {:object, "name"}]
      assert PathUtils.reconstruct_path(segments) == "/items/5/name"
    end

    test "escapes special characters" do
      segments = [{:object, "foo~bar"}, {:object, "baz/qux"}]
      assert PathUtils.reconstruct_path(segments) == "/foo~0bar/baz~1qux"
    end

    test "reconstructs empty path as root" do
      assert PathUtils.reconstruct_path([]) == "/"
    end
  end
end
