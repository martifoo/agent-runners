#!/usr/bin/env bash
# Remove the ar PATH shim. With --purge, also drop msb state and config.
set -euo pipefail

BIN_DIR="${AR_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${AR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ar}"
SNAPSHOT_NAME="${AR_SNAPSHOT_NAME:-ar-base}"
NPM_VOLUME="${AR_NPM_VOLUME:-ar-npm}"
HOME_VOLUME="${AR_HOME_VOLUME:-ar-home}"
CODEX_HOME_VOLUME="${AR_CODEX_HOME_VOLUME:-ar-codex-home}"
GROK_HOME_VOLUME="${AR_GROK_HOME_VOLUME:-ar-grok-home}"

purge=0
for arg in "$@"; do
  case "$arg" in
    --purge|-p) purge=1 ;;
    -h|--help|help)
      cat <<'EOF'
Usage: uninstall.sh [--purge]

  (default)  Remove the ar command from PATH (~/.local/bin/ar).
  --purge    Also remove the base snapshot, cache volumes, and ~/.config/ar.

Does not delete this git checkout.
EOF
      exit 0
      ;;
    *)
      echo "ar: unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

shim="$BIN_DIR/ar"
if [[ -e "$shim" || -L "$shim" ]]; then
  rm -f "$shim"
  echo "Removed $shim"
else
  echo "No shim at $shim"
fi

if ((purge)); then
  if command -v msb >/dev/null 2>&1; then
    if msb snapshot list 2>/dev/null | grep -qE "(^|[[:space:]])${SNAPSHOT_NAME}([[:space:]]|$)"; then
      msb snapshot remove "$SNAPSHOT_NAME" 2>/dev/null \
        && echo "Removed snapshot $SNAPSHOT_NAME" \
        || echo "Could not remove snapshot $SNAPSHOT_NAME" >&2
    else
      echo "No snapshot $SNAPSHOT_NAME"
    fi

    for vol in "$HOME_VOLUME" "$NPM_VOLUME" "$CODEX_HOME_VOLUME" "$GROK_HOME_VOLUME"; do
      if msb volume list 2>/dev/null | grep -qE "(^|[[:space:]])${vol}([[:space:]]|$)"; then
        msb volume remove "$vol" 2>/dev/null \
          && echo "Removed volume $vol" \
          || echo "Could not remove volume $vol" >&2
      else
        echo "No volume $vol"
      fi
    done
  else
    echo "msb not on PATH — skipped snapshot/volume cleanup"
  fi

  if [[ -e "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    echo "Removed $CONFIG_DIR"
  else
    echo "No config at $CONFIG_DIR"
  fi
else
  echo
  echo "Left in place (use --purge to remove):"
  echo "  config:   $CONFIG_DIR"
  echo "  snapshot: $SNAPSHOT_NAME"
  echo "  volumes:  $HOME_VOLUME $NPM_VOLUME $CODEX_HOME_VOLUME $GROK_HOME_VOLUME"
  echo "  checkout: (this repo)"
fi

echo
echo "Uninstall complete."
