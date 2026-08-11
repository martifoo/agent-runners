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

@test "codex runner has a bare entrypoint; startup and login live in the launcher" {
  df="$REPO/runners/codex/Dockerfile"
  grep -q 'ENTRYPOINT \["codex"\]' "$df"
  ! grep -q 'codex-entry' "$df"
}

@test "codex's OPENAI_API_KEY auto-login lives in the README wrapper, not the image" {
  grep -q 'codex login status' "$REPO/README.md"
  grep -q 'codex login --with-api-key' "$REPO/README.md"
  # Never forces an auth method (subscription must still work).
  ! grep -q 'forced_login_method' "$REPO/README.md"
  ! grep -q 'codex-entry' "$REPO/README.md"
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

@test "README defines the shared agent-runner functions used by every launcher" {
  grep -q '_agent_runner_flags()' "$REPO/README.md"
  grep -q '_agent_runner_wrapper()' "$REPO/README.md"
  [ "$(grep -c '_agent_runner_flags || return 1' "$REPO/README.md")" -eq 3 ]
  [ "$(grep -c '_agent_runner_wrapper ' "$REPO/README.md")" -ge 3 ]
}

@test "README's manifest resolution uses readlink -f, not realpath or a bash-only nameref" {
  grep -q 'readlink -f' "$REPO/README.md"
  ! grep -q 'realpath' "$REPO/README.md"
  ! grep -q 'local -n' "$REPO/README.md"
}

@test "README launchers override the entrypoint via --script-path/--entrypoint" {
  grep -q -- '--script-path' "$REPO/README.md"
  grep -q -- '--entrypoint /bin/sh' "$REPO/README.md"
}

@test "README documents the agent-runner manifest and startup script" {
  grep -q '.agent-runner/startup.sh' "$REPO/README.md"
  grep -q '.agent-runner/manifest' "$REPO/README.md"
  grep -qi 'source:destination' "$REPO/README.md"
}

@test "README's isolation section covers the registered-in manifest/startup.sh" {
  awk '/^## Isolation/,/^## Build an image/' "$REPO/README.md" | grep -q '.agent-runner'
}
