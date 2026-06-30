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

# NOTE: no --ignore-scripts: codex ships a native binary that its postinstall
# script fetches; skipping scripts leaves a non-runnable stub.
RUN npm install -g @openai/codex@0

# Entrypoint shim: this Codex version does not authenticate from OPENAI_API_KEY
# alone (it still shows the sign-in/onboarding screen) — it needs an auth.json.
# So if the key is present and we are not already logged in, log in with it
# (writes auth.json inside this ephemeral sandbox; no secret is baked into the
# image). With no key, we fall through to Codex's normal flow, which supports
# ChatGPT subscription login. An existing login is never overwritten, so a
# persisted (--name) subscription session keeps working.
RUN cat > /usr/local/bin/codex-entry <<'SH'
#!/usr/bin/env sh
if [ -n "${OPENAI_API_KEY:-}" ] && ! codex login status >/dev/null 2>&1; then
  printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1 || true
fi
exec codex "$@"
SH
RUN chmod +x /usr/local/bin/codex-entry

# Codex runs inside the msb microVM, which IS the isolation boundary, so its own
# bubblewrap sandbox would be a redundant nested sandbox around the commands it
# runs — and bubblewrap needs unprivileged user namespaces the microVM may not
# provide (the "could not find bubblewrap" fallback warning). Disable Codex's
# inner sandbox and rely on the microVM, matching the trust model the claude
# runner uses for /workspace.
#
# Security note: this lets Codex run commands without an inner sandbox. It is
# acceptable ONLY because the microVM isolates the host; /workspace is still a
# host bind mount and egress is open by default, so harden per-run with msb
# network rules (--no-net / --net-rule) or a read-only mount for untrusted code.
RUN mkdir -p /root/.codex && cat > /root/.codex/config.toml <<'TOML'
sandbox_mode = "danger-full-access"

# Pre-trust the mounted workspace so Codex skips its first-run "trust this
# folder?" prompt — same rationale and trust model as sandbox_mode above (the
# microVM is the boundary), mirroring the claude runner pre-trusting /workspace.
[projects."/workspace"]
trust_level = "trusted"
TOML

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/codex-entry"]
