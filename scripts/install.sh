#!/usr/bin/env bash
# Install agr onto PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${AGR_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

# Keep a stable path to the repo checkout so upgrades are a git pull away.
# The installed shim always execs the checkout's bin/agr.
cat > "$BIN_DIR/agr" <<EOF
#!/usr/bin/env bash
exec "$ROOT/bin/agr" "\$@"
EOF
chmod 755 "$BIN_DIR/agr"

# Drop the old `ar` shim if present (renamed to avoid clashing with Unix ar(1)).
if [[ -e "$BIN_DIR/ar" || -L "$BIN_DIR/ar" ]]; then
  rm -f "$BIN_DIR/ar"
  echo "Removed old shim: $BIN_DIR/ar"
fi

echo "Installed: $BIN_DIR/agr"
echo "  → $ROOT/bin/agr"
echo
echo "Make sure $BIN_DIR is on your PATH."
echo
echo "  agr claude"
echo "  agr codex"
echo "  agr pi"
echo "  agr grok"
echo
echo "First run builds the base snapshot automatically."
echo
echo "Config moved: ~/.config/ar → ~/.config/agr (migrate manually if needed)."
