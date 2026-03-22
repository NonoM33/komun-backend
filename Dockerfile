# ── Build stage ──────────────────────────────────────────────────────────────
FROM hexpm/elixir:1.19.5-erlang-28.3-debian-bullseye-20250428-slim AS builder

RUN apt-get update -y && apt-get install -y build-essential git curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Cache deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/
COPY config/prod.exs config/
COPY config/runtime.exs config/

RUN mix deps.compile

COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM debian:bullseye-slim AS app

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/komun_backend ./

USER nobody

ENV PHX_SERVER=true
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:4000/api/health || exit 1

ENTRYPOINT ["/app/bin/komun_backend"]
CMD ["start"]
