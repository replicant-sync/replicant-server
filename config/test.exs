import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :replicant_server, ReplicantServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "replicant_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Test-only endpoint hosting the sync socket (see ReplicantServer.Sync.ChannelCase)
config :replicant_server, ReplicantServer.Sync.TestEndpoint,
  secret_key_base: "oD6r/Ez+1r8Dh1dGG7dZ8BQS3wcNOYQsXgrATKe1LCimCFRoO346xxuWJBbga1bE",
  pubsub_server: ReplicantServer.PubSub,
  server: false

config :replicant_server, :sync_test_endpoint, ReplicantServer.Sync.TestEndpoint

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
