#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. /.msb/scripts/guest-common

# Grok home may be a named volume (bin + auth + config). Seed defaults every run.
mkdir -p /root/.grok

# MicroVM is the isolation boundary — auto-approve tools and pin a dark theme
# that quantizes cleanly even without truecolor (GrokNight).
cat > /root/.grok/config.toml <<'TOML'
[cli]
installer = "internal"

[ui]
default_selected_permission = "always_allow_all_sessions"
theme = "groknight"
TOML

# Skip the first-run "trust this folder?" prompt for the mounted workspace.
# Same store as local grok: ~/.grok/trusted_folders.toml
cat > /root/.grok/trusted_folders.toml <<'TOML'
[folders."/workspace"]
trusted = true
TOML

run_host_startup
ensure_grok_latest

# Auth: XAI_API_KEY / GROK_DEPLOYMENT_KEY via env, or prior grok login on the
# ar-grok-home volume (auth.json). Grok accepts the env key directly.
if [[ -z "${XAI_API_KEY:-}" && -z "${GROK_DEPLOYMENT_KEY:-}" ]]; then
  if [[ ! -f /root/.grok/auth.json ]]; then
    echo "ar: no XAI_API_KEY / GROK_DEPLOYMENT_KEY / ~/.grok/auth.json; grok may prompt to login" >&2
  fi
fi

export GROK_SANDBOX="${GROK_SANDBOX:-off}"
# MicroVM has no desktop appearance API; force dark so auto-theme doesn't
# flip to light and look washed out.
export GROK_APPEARANCE="${GROK_APPEARANCE:-dark}"
export GROK_THEME="${GROK_THEME:-groknight}"

cd /workspace
# bypassPermissions + always-approve: microVM is the boundary.
exec grok --permission-mode bypassPermissions --always-approve "$@"
