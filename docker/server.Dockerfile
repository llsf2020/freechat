# FreeChat homeserver: Tuwunel at its upstream baseline plus FreeChat patches.
#
#   docker build -f docker/server.Dockerfile -t freechat-server .
#
# main builds on Debian 13. The ubuntu-24.04 and ubuntu-26.04 branches differ from main only in the two
# FROM lines (published as freechat-server:ubuntu24.04 and :ubuntu26.04). The build stage must not have a
# newer glibc than the runtime stage, or the binary will not start.

FROM rust:1.95-trixie@sha256:f49565f188ee00bc2a18dd418183f2c5f23ef7d6e691890517ed341a598f67c3 AS build
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

FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db
# Security updates released after the base image was built.
RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
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
