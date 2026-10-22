# FreeChat homeserver: Tuwunel at its upstream baseline plus FreeChat patches.
#
#   docker build -f docker/server.Dockerfile -t freechat-server .

FROM rust:1.95-bookworm@sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1 AS build
ARG TARGETARCH
RUN apt-get update \
	&& apt-get install -y --no-install-recommends clang libclang-dev liburing-dev cmake pkg-config libssl-dev git \
	&& rm -rf /var/lib/apt/lists/*
WORKDIR /freechat
COPY upstream.conf ./
COPY docker/checkout.sh docker/
COPY patches/tuwunel patches/tuwunel
RUN docker/checkout.sh tuwunel /src
WORKDIR /src
RUN --mount=type=cache,target=/usr/local/cargo/registry \
	--mount=type=cache,target=/usr/local/cargo/git \
	--mount=type=cache,target=/src/target,id=tuwunel-target-${TARGETARCH} \
	cargo build --release --locked --bin tuwunel \
	&& cp target/release/tuwunel /usr/local/bin/tuwunel

FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update \
	&& apt-get install -y --no-install-recommends liburing2 ca-certificates \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd --system --uid 10001 --home-dir /var/lib/tuwunel tuwunel \
	&& mkdir -p /var/lib/tuwunel /etc/tuwunel \
	&& chown tuwunel /var/lib/tuwunel
COPY --from=build /usr/local/bin/tuwunel /usr/local/bin/tuwunel
USER tuwunel
ENV TUWUNEL_CONFIG=/etc/tuwunel/tuwunel.toml
VOLUME /var/lib/tuwunel
EXPOSE 8008
ENTRYPOINT ["/usr/local/bin/tuwunel"]
