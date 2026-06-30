FROM node:24-bookworm
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     bash curl wget ca-certificates git ripgrep fd-find \
     iputils-ping dnsutils procps less vim nano jq unzip sudo \
  && rm -rf /var/lib/apt/lists/*
# NOTE: no --ignore-scripts: claude-code ships a native binary that its
# postinstall script fetches; skipping scripts leaves a non-runnable stub.
RUN npm install -g @anthropic-ai/claude-code@2

# Claude Code refuses --dangerously-skip-permissions (bypass-permissions mode)
# when running as root "for security reasons". This image runs as root inside
# the msb microVM, which is itself the isolation boundary, so we declare the
# sandbox with IS_SANDBOX=1 — the supported override that lets bypass mode run
# as root. The launcher (claude-box) also passes --env IS_SANDBOX=1, since msb
# does not propagate image ENV into the microVM.
ENV IS_SANDBOX=1

# Pre-seed Claude Code state so the first run skips the interactive setup:
# the theme picker, onboarding, the /workspace "trust this folder" prompt, and
# the one-time "Bypass Permissions mode" acceptance warning
# (bypassPermissionsModeAccepted, paired with the bypass default below).
# Keys verified against the claude-code 2.x config schema (~/.claude.json).
#
# Security note: hasTrustDialogAccepted pre-trusts /workspace and bypass mode
# runs tools without prompts, so a mounted repo's code/config/hooks execute
# without confirmation. This is acceptable here ONLY because the agent runs
# inside a microsandbox microVM (the isolation boundary). Residual risk:
# /workspace is a bind mount from the host and network egress is open by default
# — a hostile repo could touch those. Harden per-run with msb network rules
# (e.g. --no-net / --net-rule) or a read-only mount if you run untrusted code.
RUN cat > /root/.claude.json <<'JSON'
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

# Default to bypass-permissions mode so the agent runs tools without per-action
# prompts — appropriate because the microVM is the isolation boundary (and root
# bypass is unlocked by IS_SANDBOX=1, which the claude-box launcher passes).
# Override per run: `claude-box --permission-mode default` (a CLI flag wins).
RUN mkdir -p /root/.claude && cat > /root/.claude/settings.json <<'JSON'
{
  "permissions": { "defaultMode": "bypassPermissions" }
}
JSON

WORKDIR /workspace
ENTRYPOINT ["claude"]
