# ── Build stage ──────────────────────────────────────────────────────────────
FROM elixir:1.17-slim AS builder

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
FROM debian:bookworm-slim AS app

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/komun_backend ./

# Persistent uploads directory (mounted as a volume in production).
# We symlink the release's priv/static/uploads to /app/uploads so that
# `Application.app_dir(:komun_backend, "priv/static/uploads")` resolves
# to the volume regardless of the release version path.
RUN mkdir -p /app/uploads && \
    sh -c 'cd /app/lib/komun_backend-* && rm -rf priv/static/uploads && ln -s /app/uploads priv/static/uploads'

# Entrypoint chowns the upload dir at runtime then drops to nobody.
# Coolify mounts the volume on top of /app/uploads with root:root ownership
# (bind mount default), so the build-time chown gets overridden. We need
# to fix permissions at container start, hence this small entrypoint.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'set -e' \
    'mkdir -p /app/uploads' \
    'chown -R nobody:root /app/uploads' \
    'exec runuser -u nobody -- /bin/sh -c "/app/bin/komun_backend eval '"'"'KomunBackend.Release.migrate()'"'"' && /app/bin/komun_backend start"' \
    > /entrypoint.sh && chmod +x /entrypoint.sh

ENV PHX_SERVER=true
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:4000/api/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
