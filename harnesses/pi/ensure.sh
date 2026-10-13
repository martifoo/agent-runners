#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. /.msb/scripts/guest-common

# Pre-trust mounted projects; microVM is the isolation boundary.
# AGR_PI_PACKAGES lists packages to install (space-separated, default none).
# `pi install` is idempotent.
read -r -a pi_packages <<<"${AGR_PI_PACKAGES:-}"

# ~/.pi persists on a volume, so merge into existing settings.
settings=/root/.pi/agent/settings.json
mkdir -p "${settings%/*}"
[[ -s "$settings" ]] || echo '{}' > "$settings"
jq '. + {defaultProjectTrust: "always", packages: $ARGS.positional}' \
  "$settings" --args "${pi_packages[@]}" > "$settings.tmp"
mv "$settings.tmp" "$settings"

run_host_startup
ensure_npm_latest "@earendil-works/pi-coding-agent" "latest" "pi" --ignore-scripts

if [[ "${AGR_OFFLINE:-0}" != "1" ]]; then
  echo "agr: ensuring pi packages…"
  for pkg in "${pi_packages[@]}"; do
    pi install "$pkg"
  done
else
  echo "agr: AGR_OFFLINE=1 — skipping pi package installs"
fi

cd /workspace
exec pi "$@"
