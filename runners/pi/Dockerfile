FROM node:24-bookworm
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     bash curl wget ca-certificates git ripgrep fd-find python3 \
     iputils-ping dnsutils procps less vim nano jq unzip sudo \
  && rm -rf /var/lib/apt/lists/*

# Install uv so MCP servers shipped as Python packages can be launched with
# `uvx` (e.g. `uvx some-mcp-server`). node:24-bookworm provides npm/npx but no
# Python toolchain, so without uv a `uv`/`uvx`-based MCP server fails to start.
# python3 (above) gives uv a system interpreter so it need not fetch a managed
# one on first run. The installer drops binaries in /root/.local/bin.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0

# Pre-trust mounted projects so pi skips its first-run "trust this folder?"
# prompt. Acceptable because the msb microVM is the isolation boundary (same
# rationale as the claude/codex runners pre-trusting /workspace).
RUN mkdir -p /root/.pi/agent && cat > /root/.pi/agent/settings.json <<'JSON'
{
  "defaultProjectTrust": "always"
}
JSON

WORKDIR /workspace
ENTRYPOINT ["pi"]
