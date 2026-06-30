#!/usr/bin/env bats

setup() { REPO="$BATS_TEST_DIRNAME/.."; }

@test "each runner Dockerfile installs the right agent package" {
  grep -q '@earendil-works/pi-coding-agent@0' "$REPO/runners/pi/Dockerfile"
  grep -q '@anthropic-ai/claude-code@2'       "$REPO/runners/claude/Dockerfile"
  grep -q '@openai/codex@0'                   "$REPO/runners/codex/Dockerfile"
}

@test "every runner installs the GitHub CLI (gh)" {
  for df in "$REPO"/runners/*/Dockerfile; do
    grep -qE '^\s*bash curl wget ca-certificates git gh ' "$df"
  done
}

@test "every runner installs uv (+python3) so uvx-based MCP servers can start" {
  # node:24-bookworm ships npm/npx but no Python toolchain, so uv must be added
  # explicitly for `uvx some-mcp-server` to work; python3 backs it.
  for df in "$REPO"/runners/*/Dockerfile; do
    grep -q 'astral.sh/uv/install.sh' "$df"
    grep -q 'ENV PATH="/root/.local/bin:${PATH}"' "$df"
    grep -q 'python3' "$df"
  done
}

@test "codex entrypoint auto-logs-in with OPENAI_API_KEY but still allows subscription" {
  df="$REPO/runners/codex/Dockerfile"
  # Uses an entrypoint shim (not bare codex) so the key path is handled.
  grep -q 'ENTRYPOINT \["/usr/local/bin/codex-entry"\]' "$df"
  # Only logs in when a key is present AND not already logged in (don't clobber
  # a persisted subscription session); otherwise falls through to `exec codex`.
  grep -q 'OPENAI_API_KEY' "$df"
  grep -q 'codex login status' "$df"
  grep -q 'codex login --with-api-key' "$df"
  grep -q 'exec codex' "$df"
  # Never forces an auth method (subscription must still work).
  ! grep -q 'forced_login_method' "$df"
}

@test "codex disables its inner sandbox (microVM is the boundary; no bubblewrap)" {
  # The msb microVM is the isolation boundary, so Codex's own bubblewrap sandbox
  # is redundant and pulls in a missing-bubblewrap warning. Disabled via config.
  grep -q 'sandbox_mode = "danger-full-access"' "$REPO/runners/codex/Dockerfile"
}

@test "codex pre-trusts /workspace (skips the trust-folder prompt)" {
  df="$REPO/runners/codex/Dockerfile"
  grep -q '\[projects."/workspace"\]' "$df"
  grep -q 'trust_level = "trusted"' "$df"
}

@test "claude runner declares the sandbox so bypass-permissions works as root" {
  # Claude Code refuses --dangerously-skip-permissions as root unless it detects
  # a sandbox; the microVM is the boundary, so IS_SANDBOX=1 enables opt-in use.
  grep -q 'ENV IS_SANDBOX=1' "$REPO/runners/claude/Dockerfile"
}

@test "claude runner defaults to bypass-permissions mode (and pre-accepts its warning)" {
  df="$REPO/runners/claude/Dockerfile"
  grep -q 'settings.json' "$df"
  grep -q '"defaultMode": "bypassPermissions"' "$df"
  # Pre-accept the one-time "Bypass Permissions mode" warning so it doesn't block.
  grep -q '"bypassPermissionsModeAccepted": true' "$df"
}

@test "pi pre-trusts projects (skips the trust-folder prompt)" {
  df="$REPO/runners/pi/Dockerfile"
  grep -q '/root/.pi/agent/settings.json' "$df"
  grep -q '"defaultProjectTrust": "always"' "$df"
}

@test "the legacy root Dockerfile and run.sh wrapper have been removed" {
  [ ! -f "$REPO/Dockerfile" ]
  [ ! -f "$REPO/run.sh" ]
  [ ! -f "$REPO/agents.conf" ]
}

@test "README documents the launcher functions and published images" {
  grep -q "msb run" "$REPO/README.md"
  grep -q "claude-box()" "$REPO/README.md"
  grep -q "ghcr.io" "$REPO/README.md"
}
