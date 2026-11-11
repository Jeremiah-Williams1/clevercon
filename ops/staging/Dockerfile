# Staging layer on top of the upstream image (built first as clevercon-base).
# Upstream's Dockerfile stays untouched; we only (1) patch the OS packages, (2) make one folder
# writable for Vite, and (3) change who runs the process.
ARG BASE_IMAGE=clevercon-base:local
FROM ${BASE_IMAGE}

USER root
RUN apt-get update \
  && apt-get -y --no-install-recommends upgrade \
  && rm -rf /var/lib/apt/lists/*

# The Vite dev server writes a temporary config file next to vite.config.ts. This changes the owner
# of that one folder only (no -R), so it adds almost nothing to the image. Everything else stays
# read-only for the node user.
RUN chown node:node /app/apps/web

USER node