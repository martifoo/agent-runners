#!/usr/bin/env bash
# Remove the agr PATH shim. With --purge, also drop msb state and config.
set -euo pipefail

BIN_DIR="${AGR_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${AGR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agr}"
LEGACY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ar"
SNAPSHOT_NAME="${AGR_SNAPSHOT_NAME:-agr-base}"
NPM_VOLUME="${AGR_NPM_VOLUME:-agr-npm}"
HOME_VOLUME="${AGR_HOME_VOLUME:-agr-home}"
CODEX_HOME_VOLUME="${AGR_CODEX_HOME_VOLUME:-agr-codex-home}"
GROK_HOME_VOLUME="${AGR_GROK_HOME_VOLUME:-agr-grok-home}"
PI_HOME_VOLUME="${AGR_PI_HOME_VOLUME:-agr-pi-home}"

purge=0
for arg in "$@"; do
  case "$arg" in
    --purge|-p) purge=1 ;;
    -h|--help|help)
      cat <<'EOF'
Usage: uninstall.sh [--purge]

  (default)  Remove the agr command from PATH (~/.local/bin/agr).
  --purge    Also remove the base snapshot, cache volumes, and ~/.config/agr.

Does not delete this git checkout.
EOF
      exit 0
      ;;
    *)
      echo "agr: unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

removed_shim=0
for shim in "$BIN_DIR/agr" "$BIN_DIR/ar"; do
  if [[ -e "$shim" || -L "$shim" ]]; then
    rm -f "$shim"
    echo "Removed $shim"
    removed_shim=1
  fi
done
if ((removed_shim == 0)); then
  echo "No shim at $BIN_DIR/agr"
fi

if ((purge)); then
  if command -v msb >/dev/null 2>&1; then
    for snap in "$SNAPSHOT_NAME" ar-base; do
      if msb snapshot list 2>/dev/null | grep -qE "(^|[[:space:]])${snap}([[:space:]]|$)"; then
        msb snapshot remove "$snap" 2>/dev/null \
          && echo "Removed snapshot $snap" \
          || echo "Could not remove snapshot $snap" >&2
      else
        echo "No snapshot $snap"
      fi
    done

    for vol in "$HOME_VOLUME" "$NPM_VOLUME" "$CODEX_HOME_VOLUME" "$GROK_HOME_VOLUME" "$PI_HOME_VOLUME" \
               ar-home ar-npm ar-codex-home ar-grok-home; do
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

  removed_cfg=0
  for dir in "$CONFIG_DIR" "$LEGACY_CONFIG_DIR"; do
    if [[ -e "$dir" ]]; then
      rm -rf "$dir"
      echo "Removed $dir"
      removed_cfg=1
    fi
  done
  if ((removed_cfg == 0)); then
    echo "No config at $CONFIG_DIR"
  fi
else
  echo
  echo "Left in place (use --purge to remove):"
  echo "  config:   $CONFIG_DIR"
  echo "  snapshot: $SNAPSHOT_NAME"
  echo "  volumes:  $HOME_VOLUME $NPM_VOLUME $CODEX_HOME_VOLUME $GROK_HOME_VOLUME $PI_HOME_VOLUME"
  echo "  checkout: (this repo)"
fi

echo
echo "Uninstall complete."
