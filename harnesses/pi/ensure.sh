#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. /.msb/scripts/guest-common

# Pre-trust mounted projects; microVM is the isolation boundary.
mkdir -p /root/.pi/agent
cat > /root/.pi/agent/settings.json <<'JSON'
{
  "defaultProjectTrust": "always"
}
JSON

run_host_startup
ensure_npm_latest "@earendil-works/pi-coding-agent" "0" "pi" --ignore-scripts

cd /workspace
exec pi "$@"
