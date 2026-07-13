import Config

# Configure your database
config :replicant_server, ReplicantServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "replicant_server_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"
