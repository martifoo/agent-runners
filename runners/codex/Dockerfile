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
RUN npm install -g @openai/codex@0

# Disable Codex's inner bubblewrap sandbox and rely on the microVM boundary.
# This runs commands without an inner sandbox, safe only because the microVM
# isolates the host. /workspace is a host bind mount and egress is open, so
# harden untrusted code per-run with msb network rules or a read-only mount.
RUN mkdir -p /root/.codex && cat > /root/.codex/config.toml <<'TOML'
sandbox_mode = "danger-full-access"

# Pre-trust the mounted workspace to skip Codex's first-run trust prompt.
[projects."/workspace"]
trust_level = "trusted"
TOML

WORKDIR /workspace
ENTRYPOINT ["codex"]
