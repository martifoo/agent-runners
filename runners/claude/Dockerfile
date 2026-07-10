FROM node:24-bookworm
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     bash curl wget ca-certificates git gh ripgrep fd-find python3 \
     iputils-ping dnsutils procps less vim nano jq unzip sudo \
  && rm -rf /var/lib/apt/lists/*

# uv lets uvx-based Python MCP servers launch (node:24 has no Python toolchain).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# No --ignore-scripts: the postinstall fetches a native binary; skipping it
# leaves a non-runnable stub.
RUN npm install -g @anthropic-ai/claude-code@2

# Claude Code refuses bypass-permissions mode as root. IS_SANDBOX=1 is the
# supported override. claude-box re-passes it because msb drops image ENV.
ENV IS_SANDBOX=1

# Pre-seed state to skip first-run setup: theme, onboarding, /workspace trust,
# and the bypass-mode acceptance. A pre-trusted /workspace runs a mounted repo's
# code without prompts, safe only because the microVM is the isolation boundary.
# /workspace is a host bind mount and egress is open, so harden untrusted code
# per-run with msb network rules or a read-only mount.
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

# Default to bypass-permissions mode so the agent runs without per-action prompts.
# Override per run with `claude-box --permission-mode default`.
RUN mkdir -p /root/.claude && cat > /root/.claude/settings.json <<'JSON'
{
  "permissions": { "defaultMode": "bypassPermissions" }
}
JSON

WORKDIR /workspace
ENTRYPOINT ["claude"]
