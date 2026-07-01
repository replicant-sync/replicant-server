# Dockerfile for Phoenix release
# Based on https://hexdocs.pm/phoenix/releases.html

ARG BUILDER_IMAGE="hexpm/elixir:1.19.4-erlang-27.2.1-alpine-3.21.6"
ARG RUNNER_IMAGE="alpine:3.21.6"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apk add --no-cache build-base git nodejs npm

# Prepare build dir
WORKDIR /app

# Set build ENV
ENV MIX_ENV="prod"

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile deps separately first
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy application code and assets
COPY priv priv
COPY lib lib
COPY assets assets

# Install npm dependencies (for vanilla-jsoneditor)
RUN cd assets && npm install --production

# Build assets (esbuild + tailwind)
RUN mix assets.deploy

# Compile the release
RUN mix compile

# Copy runtime config and build release
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# Start a new build stage for the minimal runtime image
FROM ${RUNNER_IMAGE}

RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates

WORKDIR "/app"
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"

# Copy the release from the builder stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/replicant_server ./
RUN chmod +x /app/bin/*

USER nobody

# Run migrations then start the Phoenix server
CMD /app/bin/migrate && /app/bin/server
