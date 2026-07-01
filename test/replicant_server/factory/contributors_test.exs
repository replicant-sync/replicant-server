defmodule ReplicantServer.Factory.ContributorsTest do
  use ExUnit.Case, async: true

  alias ReplicantServer.Factory.Contributors

  @config %{
    contributors: %{
      "Robert Rich" => %{email: "rr@robertrich.com", display_name: "Robert Rich"},
      "Sevish" => %{email: "sean@sevish.com", display_name: "Sevish"}
    },
    system: %{email: "factory@nodeaudio.com", display_name: "Entonal"},
    overrides: %{"7-limit-hexany" => "Sevish"}
  }

  test "resolve maps a preset's content author to its contributor" do
    assert {:ok, %{email: "rr@robertrich.com", display_name: "Robert Rich"}} =
             Contributors.resolve(@config, "Robert Rich", "partch-43-tone")
  end

  test "resolve applies a slug override even when the content author is empty" do
    assert {:ok, %{email: "sean@sevish.com", display_name: "Sevish"}} =
             Contributors.resolve(@config, "", "7-limit-hexany")
  end

  test "resolve falls back to the system user for an unauthored preset with no override" do
    assert {:ok, %{email: "factory@nodeaudio.com", display_name: "Entonal"}} =
             Contributors.resolve(@config, "", "12-tone-equal-temperament")
  end

  test "load evaluates a config file" do
    path = Path.join(System.tmp_dir!(), "factory_contributors_#{System.unique_integer([:positive])}.exs")
    File.write!(path, inspect(@config, limit: :infinity))
    assert {:ok, loaded} = Contributors.load(path)
    assert loaded.system.display_name == "Entonal"
    File.rm!(path)
  end

  test "load returns an error when the file is missing" do
    assert {:error, _} = Contributors.load("/nonexistent/factory_contributors.exs")
  end
end
