# FreeChat front: Caddy (TLS, reverse proxy) serving Element Web with FreeChat patches.
#
#   docker build -f docker/web.Dockerfile -t freechat-web .
#
# The deployment mounts its Caddyfile at /etc/caddy/Caddyfile and its
# config.json at /srv/web/config.json.

# The static build is architecture independent, so it runs natively on the builder.
FROM --platform=$BUILDPLATFORM node:24-bookworm@sha256:49f7adaf9f1574bc45c20ea317139b39a59d7e758d0e93745e112fd85cb42623 AS build
RUN corepack enable \
	&& apt-get update && apt-get install -y --no-install-recommends python3-pil \
	&& rm -rf /var/lib/apt/lists/*
WORKDIR /freechat
COPY upstream.conf ./
COPY docker/checkout.sh docker/
COPY patches/element-web patches/element-web
RUN docker/checkout.sh element-web forks/element-web
# Name, icon and colours from branding/ (see branding/README.md).
COPY branding branding
RUN python3 branding/apply.py web && ln -s /freechat/forks/element-web /src
WORKDIR /src
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 NX_DAEMON=false CI=true
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
	pnpm install --frozen-lockfile \
	&& pnpm --filter element-web build \
	&& rm -f apps/web/webapp/config.json
# The CSP Caddy sends (deploy/install.sh) must allow the inline scripts of this build.
COPY docker/check-csp.py deploy/install.sh /freechat/csp/
RUN python3 /freechat/csp/check-csp.py apps/web/webapp /freechat/csp/install.sh

FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
# Security updates released after the base image was built.
RUN apk upgrade --no-cache
COPY --from=build /src/apps/web/webapp /srv/web
