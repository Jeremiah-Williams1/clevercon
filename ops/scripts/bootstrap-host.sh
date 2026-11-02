#!/usr/bin/env bash
# CleverCon host bootstrap for a fresh Ubuntu 24.04 EC2 instance.
#
# Runs ONCE at first boot, as root, when pasted into EC2 "User data".
# Safe to re-run: every step checks before it changes anything.
#
# It installs: swap, Docker (official repo) + Compose plugin, Node 20, git, tmux, jq,
# then clones the fork over HTTPS (public repo, so no credentials needed).
#
# SECURITY: user-data is readable by anyone with access to the instance.
# This script contains NO secrets. Secrets are created later, on the host, by baseline.sh.
#
# Progress:  sudo tail -f /var/log/bootstrap.log
# Finished:  /var/lib/clevercon/bootstrap.done exists

set -euo pipefail

# ---- settings (edit here, nowhere else) -------------------------------------
REPO_URL="https://github.com/Jeremiah-Williams1/clevercon.git"
BRANCH="infra/main"
TARGET_USER="ubuntu"          # default login user on Ubuntu AMIs
SWAP_SIZE="4G"
NODE_MAJOR="20"
# -----------------------------------------------------------------------------

LOG="/var/log/bootstrap.log"
MARKER_DIR="/var/lib/clevercon"
MARKER="$MARKER_DIR/bootstrap.done"

# Send everything printed below to the screen AND to the log file.
exec > >(tee -a "$LOG") 2>&1

log()  { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] BOOTSTRAP FAILED at line %s. No done-marker written.\n' "$(date -u +%H:%M:%S)" "$1"; }
trap 'fail $LINENO' ERR

[ "$(id -u)" -eq 0 ] || { echo "Run as root (user-data does this automatically)."; exit 1; }

if [ -f "$MARKER" ]; then
  log "Already bootstrapped ($MARKER exists). Nothing to do."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
# On first boot, cloud-init may still hold the apt lock; wait up to 5 min instead of failing.
APT="apt-get -o DPkg::Lock::Timeout=300 -y"

log "Starting bootstrap (user=$TARGET_USER, branch=$BRANCH)"
. /etc/os-release
echo "OS: $PRETTY_NAME"
[ "${VERSION_ID:-}" = "24.04" ] || echo "WARNING: written for Ubuntu 24.04, found ${VERSION_ID:-unknown}"
id "$TARGET_USER" >/dev/null 2>&1 || { echo "User $TARGET_USER does not exist"; exit 1; }

# ---- 1. base packages -------------------------------------------------------
log "1/6 Base packages"
$APT update
$APT install ca-certificates curl gnupg git tmux jq unzip

# ---- 2. swap ----------------------------------------------------------------
# Swap = disk space used as emergency memory. Stops npm/tsc being killed when RAM runs out.
log "2/6 Swap ($SWAP_SIZE)"
if swapon --show | grep -q .; then
  echo "swap already active, skipping"
else
  if [ ! -f /swapfile ]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---- 3. Docker (official repo) ----------------------------------------------
# The official repo gives a current Docker and Compose plugin; Ubuntu's own package is older.
log "3/6 Docker + Compose plugin"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  $APT update
  $APT install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "docker + compose already installed, skipping"
fi
systemctl enable --now docker
# docker group = permission to use Docker without sudo. Takes effect on the user's NEXT login.
usermod -aG docker "$TARGET_USER"

# ---- 4. Node ----------------------------------------------------------------
# Installed system-wide (not via nvm) because user-data runs as root, not as $TARGET_USER.
log "4/6 Node $NODE_MAJOR"
if command -v node >/dev/null && [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" = "$NODE_MAJOR" ]; then
  echo "node $(node -v) already installed, skipping"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  $APT update
  $APT install nodejs
fi

# ---- 5. clone the fork ------------------------------------------------------
# Cloned as $TARGET_USER so the files belong to them, not root. HTTPS + public repo = no keys on the server.
log "5/6 Clone $REPO_URL ($BRANCH)"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
DEST="$HOME_DIR/clevercon"
if [ -d "$DEST/.git" ]; then
  echo "$DEST already cloned, skipping"
else
  sudo -u "$TARGET_USER" git clone --branch "$BRANCH" "$REPO_URL" "$DEST"
fi

# ---- 6. summary + done marker -----------------------------------------------
log "6/6 Verify and write done marker"
mkdir -p "$MARKER_DIR"
{
  echo "finished_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "os:       $PRETTY_NAME"
  echo "docker:   $(docker --version)"
  echo "compose:  $(docker compose version --short)"
  echo "node:     $(node -v)"
  echo "npm:      $(npm -v)"
  echo "git:      $(git --version)"
  echo "tmux:     $(tmux -V)"
  echo "jq:       $(jq --version)"
  echo "swap_mb:  $(free -m | awk '/Swap:/{print $2}')"
  echo "repo:     $DEST @ $(sudo -u "$TARGET_USER" git -C "$DEST" rev-parse --short HEAD) ($BRANCH)"
} | tee "$MARKER"

log "BOOTSTRAP DONE. Log in again (so the docker group applies) and cd ~/clevercon."
