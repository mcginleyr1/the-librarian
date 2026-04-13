ARG ELIXIR_VERSION=1.20.0
ARG OTP_VERSION=29.0.1
ARG DEBIAN_VERSION=bookworm-20260518-slim

# No stable hexpm/elixir combined image exists for 1.20.0 yet, so build from the
# official Erlang base and install the precompiled Elixir (otp-29) release on top.
ARG BUILDER_IMAGE="hexpm/erlang:${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

ARG ELIXIR_VERSION

RUN apt-get update -y && \
    apt-get install -y build-essential git nodejs npm curl unzip ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install precompiled Elixir built for OTP 29
RUN curl -fsSL "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-29.zip" -o /tmp/elixir.zip && \
    unzip -q /tmp/elixir.zip -d /usr/local/elixir && \
    rm /tmp/elixir.zip
ENV PATH="/usr/local/elixir/bin:${PATH}"

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/runtime.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

RUN mix assets.deploy
RUN mix compile
RUN mix release && chmod +x _build/prod/rel/librarian/bin/start

FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG="en_US.UTF-8" LANGUAGE="en_US:en" LC_ALL="en_US.UTF-8"

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod" PHX_SERVER="true"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/librarian ./

USER nobody

EXPOSE 4000

CMD ["/app/bin/start"]
