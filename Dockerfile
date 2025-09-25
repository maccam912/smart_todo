############################
# Builder image
############################
FROM alpine:3.18 AS build

# Install Erlang/Elixir toolchain and build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    python3 \
    erlang \
    erlang-dev \
    erlang-parsetools \
    erlang-crypto \
    erlang-ssl \
    erlang-sasl \
    erlang-inets \
    erlang-public-key \
    elixir \
    openssl-dev

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

# Install Hex and Rebar locally
RUN mix local.hex --force \
    && mix local.rebar --force

# Leverage Docker layer caching by fetching deps before copying source
COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod \
    && mix deps.compile

# Copy app sources and assets
COPY lib lib
COPY priv priv
COPY assets assets

# Compile the application and assets, then produce a release
RUN mix compile \
    && mix assets.deploy \
    && mix release

############################
# Minimal runtime image
############################
FROM alpine:3.18 AS runtime

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

WORKDIR /app

# Install only the shared libraries required by the release
RUN apk add --no-cache libstdc++ openssl ncurses-libs

# Create an unprivileged user to run the application
RUN adduser --system --no-create-home --home /app --shell /bin/sh app

# Copy release from builder stage
COPY --from=build /app/_build/prod/rel/smart_todo ./

RUN chown -R app:app /app
USER app

EXPOSE 4000

ENTRYPOINT ["bin/smart_todo"]
CMD ["start"]
