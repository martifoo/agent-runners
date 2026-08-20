#!/usr/bin/env bash
# Provision the shared base environment inside a throwaway sandbox.
# Used by `ar build-base` to produce the msb snapshot.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  bash curl wget ca-certificates git gh ripgrep fd-find python3 \
  iputils-ping dnsutils procps less vim nano jq unzip sudo
rm -rf /var/lib/apt/lists/*

# uv lets uvx-based Python MCP servers launch (node image has no Python toolchain).
# Install into /usr/local so a later named-volume mount over /root/.local
# (used to cache claude/codex binaries) cannot shadow it.
curl -LsSf https://astral.sh/uv/install.sh | sh
if [[ -x /root/.local/bin/uv ]]; then
  install -m 755 /root/.local/bin/uv /usr/local/bin/uv
  # uvx is often a sibling shim/symlink
  if [[ -e /root/.local/bin/uvx ]]; then
    install -m 755 /root/.local/bin/uvx /usr/local/bin/uvx 2>/dev/null \
      || ln -sfn uv /usr/local/bin/uvx
  fi
fi

# Persist PATH for future boots from this snapshot.
# shellcheck disable=SC2016
if ! grep -q '/root/.local/bin' /root/.profile 2>/dev/null; then
  printf '\nexport PATH="/root/.local/bin:/usr/local/bin:%s"\n' '$PATH' >> /root/.profile
fi
if ! grep -q '/root/.local/bin' /root/.bashrc 2>/dev/null; then
  printf '\nexport PATH="/root/.local/bin:/usr/local/bin:%s"\n' '$PATH' >> /root/.bashrc
fi
export PATH="/root/.local/bin:/usr/local/bin:${PATH}"

# Warm npm a bit; harness packages themselves are installed at run time.
npm config set fund false
npm config set update-notifier false

echo "base provision complete"
node --version
npm --version
command -v uv
command -v gh
command -v rg
