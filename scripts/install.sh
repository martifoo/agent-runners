#!/usr/bin/env bash
# Install ar onto PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${AR_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

# Keep a stable path to the repo checkout so upgrades are a git pull away.
# The installed shim always execs the checkout's bin/ar.
cat > "$BIN_DIR/ar" <<EOF
#!/usr/bin/env bash
exec "$ROOT/bin/ar" "\$@"
EOF
chmod 755 "$BIN_DIR/ar"

echo "Installed: $BIN_DIR/ar"
echo "  → $ROOT/bin/ar"
echo
echo "Make sure $BIN_DIR is on your PATH."
echo
echo "  ar claude"
echo "  ar codex"
echo "  ar pi"
echo "  ar grok"
echo
echo "First run builds the base snapshot automatically."
