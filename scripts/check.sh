#!/usr/bin/env bash
# Lightweight checks — syntax, layout, dotenv unit test.
# No msb, no network, no bats.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
pass() { printf 'ok  - %s\n' "$1"; }
bad()  { printf 'FAIL- %s\n' "$1" >&2; fail=1; }

echo "== syntax (bash -n) =="
while IFS= read -r -d '' f; do
  if bash -n "$f"; then
    pass "bash -n ${f#"$ROOT"/}"
  else
    bad "bash -n ${f#"$ROOT"/}"
  fi
done < <(find "$ROOT" \( -path "$ROOT/.git" -o -path "$ROOT/docs" \) -prune -o \
  -type f \( -name '*.sh' -o -path "$ROOT/bin/*" \) -print0)

echo
echo "== layout =="
for f in \
  bin/agr \
  lib/agr.sh \
  lib/guest-common.sh \
  base/provision.sh \
  scripts/install.sh \
  scripts/uninstall.sh \
  harnesses/claude/ensure.sh \
  harnesses/codex/ensure.sh \
  harnesses/pi/ensure.sh \
  harnesses/grok/ensure.sh
do
  if [[ -f "$ROOT/$f" ]]; then
    pass "exists $f"
  else
    bad "missing $f"
  fi
done

if [[ -x "$ROOT/bin/agr" ]]; then
  pass "bin/agr executable"
else
  bad "bin/agr not executable"
fi

echo
echo "== dotenv unit test =="
# shellcheck source=/dev/null
. "$ROOT/lib/agr.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AGR_CONFIG_DIR="$tmp"

# Missing .env is fine.
AGR_DOTENV_FLAGS=(sentinel)
agr_load_dotenv
if ((${#AGR_DOTENV_FLAGS[@]} == 0)); then
  pass "missing .env → empty flags"
else
  bad "missing .env should clear/empty flags (got ${#AGR_DOTENV_FLAGS[@]})"
fi

cat > "$tmp/.env" <<'EOF'
# comment
ANTHROPIC_API_KEY=sk-test
export OPENAI_API_KEY="quoted-value"
OPENROUTER_API_KEY='single-quoted'
GH_TOKEN=plain
not a valid line
EMPTY=
EOF
chmod 600 "$tmp/.env"

agr_load_dotenv
# Expect 5 KEY=value entries → 10 array slots (--env KEY=val pairs)
expected=(
  --env ANTHROPIC_API_KEY=sk-test
  --env OPENAI_API_KEY=quoted-value
  --env OPENROUTER_API_KEY=single-quoted
  --env GH_TOKEN=plain
  --env EMPTY=
)
if [[ "${AGR_DOTENV_FLAGS[*]}" == "${expected[*]}" ]]; then
  pass "parses keys, export prefix, quotes; skips junk"
else
  bad "dotenv parse mismatch"
  printf '  got:  %s\n' "${AGR_DOTENV_FLAGS[*]}" >&2
  printf '  want: %s\n' "${expected[*]}" >&2
fi

# Loose perms should warn (non-fatal).
chmod 644 "$tmp/.env"
warn="$(agr_load_dotenv 2>&1 >/dev/null || true)"
if [[ "$warn" == *"should be chmod 600"* ]]; then
  pass "warns on loose .env perms"
else
  bad "expected chmod 600 warning, got: ${warn:-<empty>}"
fi

echo
if ((fail)); then
  echo "checks failed" >&2
  exit 1
fi
echo "all checks passed"
