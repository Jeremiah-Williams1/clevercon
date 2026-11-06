# Staging layer on top of the upstream image (built first as clevercon-base).
# Upstream's Dockerfile stays untouched; we only change who runs the process.
ARG BASE_IMAGE=clevercon-base:local
FROM ${BASE_IMAGE}

RUN mkdir -p apps/web/node_modules/.vite \
 && chown node:node apps/web apps/web/node_modules/.vite

# The node:20 image already ships a non-root "node" user (uid 1000).
# Nothing in /app needs to be writable at runtime, so we do not chown it
# (that would duplicate the whole node_modules layer).
USER node