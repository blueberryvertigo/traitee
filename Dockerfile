# ==============================================================================
# Stage 1: Build
# ==============================================================================
FROM elixir:1.17-otp-27-slim AS build

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

# ==============================================================================
# Stage 2: Runtime
# ==============================================================================
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses6 \
      locales \
      ca-certificates \
      curl \
      && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

RUN groupadd --system traitee && \
    useradd --system --gid traitee --home-dir /app --shell /bin/sh traitee && \
    mkdir -p /home/traitee/.traitee && \
    chown -R traitee:traitee /app /home/traitee

COPY --from=build --chown=traitee:traitee /app/_build/prod/rel/traitee ./

USER traitee

ENV HOME=/home/traitee
ENV PHX_HOST=0.0.0.0
ENV PORT=4000

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:4000/api/health || exit 1

CMD ["bin/traitee", "start"]
