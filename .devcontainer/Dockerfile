FROM hexpm/elixir:1.19.5-erlang-28.4.3-debian-bookworm-20260803-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      build-essential ca-certificates curl git postgresql-client \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8

WORKDIR /workspace/tidewake
