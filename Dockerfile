# Dockerfile for Phoenix release
# Based on https://hexdocs.pm/phoenix/releases.html

ARG BUILDER_IMAGE="hexpm/elixir:1.19.4-erlang-27.2.1-debian-trixie-20260223-slim"
ARG RUNNER_IMAGE="debian:trixie-20260223-slim"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

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

# Copy all source and config, then compile in one step
COPY config config
COPY priv priv
COPY lib lib
COPY rel rel
RUN mix compile && mix release

# Start a new build stage for the minimal runtime image
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

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

USER nobody

# Start the Phoenix server
CMD ["/app/bin/server"]
