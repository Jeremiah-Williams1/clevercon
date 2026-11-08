# Staging layer on top of the upstream image (built first as clevercon-base).
# Upstream's Dockerfile stays untouched; we only (1) patch the OS packages and (2) change who runs the process.
ARG BASE_IMAGE=clevercon-base:local
FROM ${BASE_IMAGE}

# Security patches for the Debian layer. The base image is rebuilt only now and then, so fixes
# published since (libgnutls30, perl-base ...) are missing from it. Runs as root, then drops privileges.
USER root
RUN apt-get update \
  && apt-get -y --no-install-recommends upgrade \
  && rm -rf /var/lib/apt/lists/*

# The node:20 image already ships a non-root "node" user (uid 1000).
# Nothing in /app needs to be writable at runtime, so we do not chown it
# (that would duplicate the whole node_modules layer).
USER node