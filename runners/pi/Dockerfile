FROM node:24-bookworm
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     bash curl wget ca-certificates git gh ripgrep fd-find python3 \
     iputils-ping dnsutils procps less vim nano jq unzip sudo \
  && rm -rf /var/lib/apt/lists/*

# uv lets uvx-based Python MCP servers launch (node:24 has no Python toolchain).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0

# Pre-trust mounted projects; the msb microVM is the isolation boundary.
RUN mkdir -p /root/.pi/agent && cat > /root/.pi/agent/settings.json <<'JSON'
{
  "defaultProjectTrust": "always"
}
JSON

WORKDIR /workspace
ENTRYPOINT ["pi"]
