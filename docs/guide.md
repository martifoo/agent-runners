# agr guide

Full reference for [agr](../README.md) — coding agents in microsandbox microVMs.

## How it works

Two layers, different update clocks:

```text
host: agr claude | agr codex | agr pi | agr grok
  credentials via ~/.config/agr/.env
           │
           ▼
  base snapshot (rare)     node + git, gh, rg, uv, …
           │ every launch
           ▼
  ensure latest agent      official installer / npm
  seed trust + config
  exec agent on $PWD
```

| Layer | What | When it changes |
|---|---|---|
| **Base snapshot** | OS tools shared by every agent | `agr build-base` / first run |
| **Harness ensure** | the agent itself | **every launch** — skipped if already latest |

No Docker. No image registry. `msb` pulls a stock Node image once, snapshots
the tools, and reuses that until you rebuild.

### Agents

| Command | Agent | Install channel |
|---|---|---|
| `agr claude` | [Claude Code](https://claude.ai/code) | `claude.ai/install.sh` |
| `agr codex` | [OpenAI Codex](https://openai.com/codex) | `chatgpt.com/codex/install.sh` |
| `agr pi` | [pi](https://github.com/badlogic/pi-mono) | npm `@earendil-works/pi-coding-agent` |
| `agr grok` | [Grok](https://x.ai/cli) | `x.ai/cli/install.sh` |

Each launch re-runs the official installer (or `npm i -g @major`). Installers
are idempotent; binaries/caches live on named volumes so upgrades stay cheap.

## Usage

```bash
agr claude
agr codex
agr pi
agr grok

agr claude "explain the auth flow"
agr codex --version

CPUS=8 MEMORY=8G agr claude
agr claude --rebuild-base
agr claude --offline

agr build-base
agr help
```

## Configuration

Config lives under XDG (`$XDG_CONFIG_HOME/agr`, default `~/.config/agr`).
Override with `AGR_CONFIG_DIR`. Keep the directory `chmod 700`.

### `~/.config/agr/.env`

**Secrets go here** — plain dotenv (`KEY=value`), not a shell script.
Parsed on the host and injected into the VM as env vars. Keep it `chmod 600`;
agr warns if group/other can read it.

```dotenv
ANTHROPIC_API_KEY=…
OPENAI_API_KEY=…
XAI_API_KEY=…
OPENROUTER_API_KEY=…
GH_TOKEN=…
```

Why not name the shell hook `.env`? Because `.env` means dotenv everywhere else.
Sourcing a file called `.env` as bash is a footgun.

Keys already in your host shell (`ANTHROPIC_*`, `OPENAI_API_KEY`,
`CODEX_ACCESS_TOKEN`, `XAI_API_KEY`, `GROK_DEPLOYMENT_KEY`, `OPENROUTER_API_KEY`,
`GH_TOKEN`) are also forwarded when set. Prefer `.env` for secrets you don’t
want in the parent environment.

**Claude subscription:** put `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`
in `.env`.

**Codex API key:** set `OPENAI_API_KEY` — agr runs `codex login --with-api-key` and
stores `auth.json` on the `agr-codex-home` volume (skips the login screen).

**Codex subscription:** omit the API key and complete ChatGPT login once; auth
persists on that volume. Or copy a host `~/.codex/auth.json` via `manifest`.
Bare env vars alone do **not** skip the interactive login screen.

**Grok:** set `XAI_API_KEY` (from [console.x.ai](https://console.x.ai)). Unlike
Codex, Grok accepts the env key directly. Optional: `GROK_DEPLOYMENT_KEY` for
enterprise, or complete `grok login` once — `auth.json` lives on `agr-grok-home`.

### `~/.config/agr/startup.sh`

Optional shell hook sourced **inside the VM** before the agent starts — git
identity, one-off `apt` installs, etc. **Not** for secrets (use `.env`).

```sh
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

If this file holds secrets anyway, keep it `chmod 600` (agr warns otherwise).

### `~/.config/agr/manifest`

One `source:destination` pair per line. Host files are copied into the VM
before boot (one-way):

```text
~/.gitconfig:/root/.gitconfig
```

For GitHub, prefer `GH_TOKEN` over copying `~/.config/gh` — on macOS the real
token usually lives in the Keychain.

## Safety

**Boundary = the microVM**, not the agent’s permission UI.

Inside the VM, agr loosens agent guardrails so work isn’t blocked by prompts:

- Claude → bypass-permissions (`IS_SANDBOX=1`)
- Codex → `sandbox_mode = danger-full-access`
- Grok → `--permission-mode bypassPermissions --always-approve`, `GROK_SANDBOX=off`, `/workspace` pre-trusted, dark theme
- All → `/workspace` pre-trusted

Still crosses the boundary:

| Into the VM | Risk |
|---|---|
| `$PWD` → `/workspace` | agent can edit your real project files |
| Network egress (open) | agent can reach the internet |
| `.env` + `startup.sh` + `manifest` | agent can read what you injected |

For untrusted code: clean directory, minimal `~/.config/agr`, read-only mount, or msb
network rules. Never point agr at secrets you wouldn’t paste into a chat.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `CPUS` | `2` | virtual CPUs |
| `MEMORY` | `2G` | guest memory |
| `AGR_BASE_IMAGE` | `node:24-bookworm` | image used to build the base |
| `AGR_SNAPSHOT_NAME` | `agr-base` | msb snapshot name |
| `AGR_CONFIG_DIR` | `~/.config/agr` | startup + manifest (`$XDG_CONFIG_HOME/agr`) |
| `AGR_NPM_VOLUME` | `agr-npm` | npm cache (pi) |
| `AGR_HOME_VOLUME` | `agr-home` | `~/.local` (claude/codex bins) |
| `AGR_CODEX_HOME_VOLUME` | `agr-codex-home` | full `~/.codex` (auth.json + packages) |
| `AGR_GROK_HOME_VOLUME` | `agr-grok-home` | full `~/.grok` (bin + auth.json + config) |

## Layout

```text
bin/agr                    CLI
scripts/install.sh         PATH install
scripts/uninstall.sh       PATH uninstall (--purge drops state too)
base/provision.sh          base snapshot contents
harnesses/<agent>/ensure.sh
lib/agr.sh                 host launcher
lib/guest-common.sh        guest ensure helpers
scripts/check.sh           syntax + layout + dotenv unit test
```

### Add an agent

1. Add `harnesses/<name>/ensure.sh` (source `guest-common`, seed config, ensure binary, `exec`).
2. Register the name in `bin/agr`.
3. Run `./scripts/check.sh`.

## Requirements

- [microsandbox](https://microsandbox.dev) (`msb`)
- macOS (Apple Silicon) or Linux
- network on first base build and agent upgrades

**Not required:** Docker, host Node, container registry.

## FAQ

**Docker?** No — microsandbox microVMs only.

**Daily rebuilds?** No. Base snapshot is long-lived; only the agent binary is
checked on launch.

**Where are my files?** On the host. `$PWD` is bind-mounted to `/workspace`.

**Uninstall?**

```bash
agr uninstall              # PATH shim only
agr uninstall --purge      # shim + snapshot + volumes + ~/.config/agr
```

**Full reset (keep agr installed)?**

```bash
agr build-base
msb volume remove agr-home agr-npm agr-codex-home agr-grok-home
```

## Rename note (`ar` → `agr`)

The CLI was renamed from `ar` to avoid clashing with Unix `ar(1)`. After
upgrading:

```bash
./scripts/install.sh                  # installs agr, drops old ~/.local/bin/ar
mv ~/.config/ar ~/.config/agr         # if you had config under the old path
# optional: rebuild snapshot under the new name
agr build-base
```
