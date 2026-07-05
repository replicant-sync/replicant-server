import Config

# Allow the dev server to target an alternate database via DATABASE_URL.
# The integration-test harness uses this to run against a throwaway clean
# database without touching the developer's local dev database.
if config_env() == :dev do
  if database_url = System.get_env("DATABASE_URL") do
    config :replicant_server, ReplicantServer.Repo, url: database_url
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :replicant_server, ReplicantServer.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6
end
