import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
# NOTE: force_ssl is disabled here because it's a compile-time setting
# that can't read runtime env vars. SSL is handled by kamal-proxy instead.
# If you need force_ssl, uncomment below (requires rebuilding the release):
#
# config :replicant_server, ReplicantServerWeb.Endpoint,
#   force_ssl: [rewrite_on: [:x_forwarded_proto]],
#   exclude: [
#     hosts: ["localhost", "127.0.0.1"]
#   ]

# Configure Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Req

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
