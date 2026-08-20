#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. /.msb/scripts/guest-common

# Pre-trust mounted projects; microVM is the isolation boundary.
# Packages mirror a useful host defaults set; `pi install` is idempotent.
mkdir -p /root/.pi/agent
cat > /root/.pi/agent/settings.json <<'JSON'
{
  "defaultProjectTrust": "always",
  "packages": [
    "npm:pi-subagents",
    "npm:pi-mcp-adapter",
    "npm:pi-web-access"
  ]
}
JSON

run_host_startup
ensure_npm_latest "@earendil-works/pi-coding-agent" "0" "pi" --ignore-scripts

if [[ "${AGR_OFFLINE:-0}" != "1" ]]; then
  echo "agr: ensuring pi packages…"
  pi install npm:pi-subagents
  pi install npm:pi-mcp-adapter
  pi install npm:pi-web-access
else
  echo "agr: AGR_OFFLINE=1 — skipping pi package installs"
fi

cd /workspace
exec pi "$@"
