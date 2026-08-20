#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. /.msb/scripts/guest-common

# Codex home may be a named volume (auth + packages). Seed config every run.
mkdir -p /root/.codex
cat > /root/.codex/config.toml <<'TOML'
sandbox_mode = "danger-full-access"

# File store: microVMs have no useful OS keyring, and interactive TUI only
# skips login when credentials are in auth storage (not bare env vars).
cli_auth_credentials_store = "file"

# Pre-trust the mounted workspace to skip Codex's first-run trust prompt.
[projects."/workspace"]
trust_level = "trusted"
TOML

run_host_startup
ensure_codex_latest
ensure_codex_auth

cd /workspace
exec codex "$@"
