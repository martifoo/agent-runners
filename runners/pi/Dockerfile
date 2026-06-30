FROM node:24-bookworm
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     bash curl wget ca-certificates git ripgrep fd-find \
     iputils-ping dnsutils procps less vim nano jq unzip sudo \
  && rm -rf /var/lib/apt/lists/*
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
