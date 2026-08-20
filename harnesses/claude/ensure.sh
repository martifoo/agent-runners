#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. /.msb/scripts/guest-common

export IS_SANDBOX=1

# Pre-seed state to skip first-run setup. Safe only because the microVM is
# the isolation boundary; /workspace is a host bind mount.
cat > /root/.claude.json <<'JSON'
{
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "theme": "dark",
  "projects": {
    "/workspace": {
      "hasTrustDialogAccepted": true,
      "hasCompletedProjectOnboarding": true
    }
  }
}
JSON

mkdir -p /root/.claude
cat > /root/.claude/settings.json <<'JSON'
{
  "permissions": { "defaultMode": "bypassPermissions" }
}
JSON

run_host_startup
ensure_claude_latest

cd /workspace
exec claude "$@"
