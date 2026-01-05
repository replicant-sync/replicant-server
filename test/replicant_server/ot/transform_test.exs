defmodule ReplicantServer.OT.TransformTest do
  use ExUnit.Case, async: true

  alias ReplicantServer.OT.Transform

  describe "transform_add_add" do
    test "different paths - no adjustment" do
      local = %{op: "add", path: "/user/name", value: "Alice"}
      remote = %{op: "add", path: "/user/email", value: "alice@example.com"}

      {:ok, {l, r}} = Transform.transform_add_add(local, remote)
      assert l.path == "/user/name"
      assert r.path == "/user/email"
    end

    test "same path - conflict (both returned)" do
      local = %{op: "add", path: "/settings/theme", value: "dark"}
      remote = %{op: "add", path: "/settings/theme", value: "light"}

      {:ok, {l, r}} = Transform.transform_add_add(local, remote)
      assert l != nil
      assert r != nil
    end

    test "array different indices - adjusts remote up" do
      local = %{op: "add", path: "/items/2", value: "Local"}
      remote = %{op: "add", path: "/items/5", value: "Remote"}

      {:ok, {l, r}} = Transform.transform_add_add(local, remote)
      assert l.path == "/items/2"
      assert r.path == "/items/6"
    end

    test "array same index - adjusts remote up" do
      local = %{op: "add", path: "/items/3", value: "A"}
      remote = %{op: "add", path: "/items/3", value: "B"}

      {:ok, {l, r}} = Transform.transform_add_add(local, remote)
      assert l.path == "/items/3"
      assert r.path == "/items/4"
    end

    test "root-level array" do
      local = %{op: "add", path: "/1", value: "Local"}
      remote = %{op: "add", path: "/3", value: "Remote"}

      {:ok, {l, r}} = Transform.transform_add_add(local, remote)
      assert l.path == "/1"
      assert r.path == "/4"
    end
  end

  describe "transform_remove_remove" do
    test "same path - conflict" do
      local = %{op: "remove", path: "/user/temp"}
      remote = %{op: "remove", path: "/user/temp"}

      {:ok, {l, r}} = Transform.transform_remove_remove(local, remote)
      assert l != nil
      assert r != nil
    end

    test "different paths - no adjustment" do
      local = %{op: "remove", path: "/config/debug"}
      remote = %{op: "remove", path: "/config/verbose"}

      {:ok, {l, r}} = Transform.transform_remove_remove(local, remote)
      assert l.path == "/config/debug"
      assert r.path == "/config/verbose"
    end

    test "array - local removes lower index, adjusts remote down" do
      local = %{op: "remove", path: "/items/2"}
      remote = %{op: "remove", path: "/items/5"}

      {:ok, {l, r}} = Transform.transform_remove_remove(local, remote)
      assert l.path == "/items/2"
      assert r.path == "/items/4"
    end

    test "array - remote removes lower index, adjusts local down" do
      local = %{op: "remove", path: "/items/5"}
      remote = %{op: "remove", path: "/items/2"}

      {:ok, {l, r}} = Transform.transform_remove_remove(local, remote)
      assert l.path == "/items/4"
      assert r.path == "/items/2"
    end

    test "array same index - conflict" do
      local = %{op: "remove", path: "/items/3"}
      remote = %{op: "remove", path: "/items/3"}

      {:ok, {l, r}} = Transform.transform_remove_remove(local, remote)
      assert l != nil
      assert r != nil
    end
  end

  describe "transform_add_remove" do
    test "unrelated paths - no adjustment" do
      add = %{op: "add", path: "/users/new", value: %{name: "Alice"}}
      remove = %{op: "remove", path: "/posts/old"}

      {:ok, {a, r}} = Transform.transform_add_remove(add, remove)
      assert a.path == "/users/new"
      assert r.path == "/posts/old"
    end

    test "array - add before remove, adjusts remove up" do
      add = %{op: "add", path: "/items/1", value: "New"}
      remove = %{op: "remove", path: "/items/3"}

      {:ok, {a, r}} = Transform.transform_add_remove(add, remove)
      assert a.path == "/items/1"
      assert r.path == "/items/4"
    end

    test "array - add after remove, adjusts add down" do
      add = %{op: "add", path: "/items/5", value: "New"}
      remove = %{op: "remove", path: "/items/2"}

      {:ok, {a, r}} = Transform.transform_add_remove(add, remove)
      assert a.path == "/items/4"
      assert r.path == "/items/2"
    end
  end

  describe "transform_replace_replace" do
    test "same path - conflict (both returned)" do
      local = %{op: "replace", path: "/theme", value: "dark"}
      remote = %{op: "replace", path: "/theme", value: "light"}

      {:ok, {l, r}} = Transform.transform_replace_replace(local, remote)
      assert l != nil
      assert r != nil
    end

    test "different paths - no conflict" do
      local = %{op: "replace", path: "/user/name", value: "Alice"}
      remote = %{op: "replace", path: "/user/age", value: 30}

      {:ok, {l, r}} = Transform.transform_replace_replace(local, remote)
      assert l.path == "/user/name"
      assert r.path == "/user/age"
    end
  end

  describe "transform_operation_pair" do
    test "add vs add dispatches correctly" do
      local = %{op: "add", path: "/items/2", value: "local"}
      remote = %{op: "add", path: "/items/5", value: "remote"}

      {:ok, {_l, r}} = Transform.transform_operation_pair(local, remote)
      assert r.path == "/items/6"
    end

    test "test operations pass through" do
      local = %{op: "test", path: "/version", value: 1}
      remote = %{op: "add", path: "/items/0", value: "new"}

      {:ok, {l, r}} = Transform.transform_operation_pair(local, remote)
      assert l != nil
      assert r != nil
    end

    test "move operations return as-is (MVP)" do
      local = %{op: "move", from: "/a", path: "/b"}
      remote = %{op: "add", path: "/c", value: "value"}

      {:ok, {l, r}} = Transform.transform_operation_pair(local, remote)
      assert l != nil
      assert r != nil
    end

    test "remove vs add swaps arguments correctly" do
      local = %{op: "remove", path: "/items/5"}
      remote = %{op: "add", path: "/items/2", value: "new"}

      {:ok, {l, r}} = Transform.transform_operation_pair(local, remote)
      # Add at index 2 happens first, so remove index shifts UP
      assert l.path == "/items/6"
      assert r.path == "/items/2"
    end
  end

  describe "transform_patches" do
    test "transforms list of operations" do
      local_ops = [
        %{op: "add", path: "/items/0", value: "first"}
      ]

      remote_ops = [
        %{op: "add", path: "/items/0", value: "remote_first"}
      ]

      {:ok, {transformed_local, transformed_remote}} =
        Transform.transform_patches(local_ops, remote_ops)

      # Both add at /items/0
      # Local stays at /items/0, remote adjusts to /items/1
      assert length(transformed_local) == 1
      assert length(transformed_remote) == 1
    end
  end
end
