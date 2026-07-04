# Dockerfile for Phoenix release
# Based on https://hexdocs.pm/phoenix/releases.html

# Debian-based images: the Tailwind v3 standalone binary requires glibc
# (no musl/Alpine build is published for v3).
# TODO: upgrade to Tailwind v4 (which ships musl binaries) so we can switch
# back to Alpine images.
ARG BUILDER_IMAGE="hexpm/elixir:1.19.4-erlang-27.3.4.9-debian-bookworm-20260610-slim"
ARG RUNNER_IMAGE="debian:bookworm-20260610-slim"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential git nodejs npm && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

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

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"

# Copy the release from the builder stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/replicant_server ./
RUN chmod +x /app/bin/*

USER nobody

# Run migrations then start the Phoenix server
CMD ["sh", "-c", "/app/bin/migrate && /app/bin/server"]
