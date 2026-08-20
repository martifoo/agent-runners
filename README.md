# agent-runners (agr)

Coding agents in throwaway [microsandbox](https://microsandbox.dev) microVMs.

```bash
cd ~/my-project
agr claude    # Claude Code
agr codex     # OpenAI Codex
agr pi        # pi
agr grok      # Grok
```

Each run boots an isolated microVM, mounts `$PWD`, installs the latest agent,
and drops you in. Exit and the VM is gone — your files stay.

## Install

Requires [`msb`](https://microsandbox.dev).

```bash
git clone https://github.com/martifoo/agent-runners.git
cd agent-runners && ./scripts/install.sh

# later: ./scripts/uninstall.sh          # remove PATH shim
#         ./scripts/uninstall.sh --purge # also snapshot, volumes, config
```

## Configure

```bash
mkdir -p ~/.config/agr && chmod 700 ~/.config/agr
cat > ~/.config/agr/.env <<'EOF'
ANTHROPIC_API_KEY=…       # or CLAUDE_CODE_OAUTH_TOKEN=…
OPENAI_API_KEY=…          # Codex (or sign in with ChatGPT once)
XAI_API_KEY=…             # Grok
OPENROUTER_API_KEY=…      # pi
GH_TOKEN=…                # optional
EOF
chmod 600 ~/.config/agr/.env
```

## Run

```bash
cd ~/my-project
agr claude
```

First launch builds a shared base snapshot (once). Later starts are fast; agents
stay on the latest release automatically.

---

[Guide](docs/guide.md) · [MIT](LICENSE)
