# Agent Runners

[![build-runners](https://github.com/martifoo/agent-runners/actions/workflows/build-runners.yml/badge.svg)](https://github.com/martifoo/agent-runners/actions/workflows/build-runners.yml)

Run coding agents — pi, Claude Code, and Codex — each inside an isolated
[microsandbox](https://microsandbox.dev) microVM, launchable from any directory.
The agent only sees the folder you start it in.

**Requirements:** [microsandbox](https://microsandbox.dev) (`msb`). Docker is only
needed to build images locally.

## Setup

1. Install **microsandbox** (`msb`) — see [microsandbox.dev](https://microsandbox.dev).

2. Add these launchers to your shell (`~/.zshrc` or `~/.bashrc`). (If you
   forked, change `_REG` to your own `ghcr.io/<owner>/` prefix.)

   ```bash
   _REG="ghcr.io/martifoo/"

   # Fills the global array _AGENT_RUNNER_FLAGS with --script-path (for
   # ~/.agent-runner/startup.sh) and --copy-file/--copy-dir (one pair per
   # ~/.agent-runner/manifest line, source:destination). A plain global, not a
   # nameref return (bash's nameref-local flag) — that syntax is bash-only and this needs to
   # run under zsh too. See "Startup script & credentials" below.
   _agent_runner_flags() {
     _AGENT_RUNNER_FLAGS=()
     [ -f "$HOME/.agent-runner/startup.sh" ] && \
       _AGENT_RUNNER_FLAGS+=(--script-path "startup:$HOME/.agent-runner/startup.sh")
     local manifest_file="$HOME/.agent-runner/manifest"
     [ -f "$manifest_file" ] || return 0
     local line src dst real
     while IFS= read -r line || [ -n "$line" ]; do
       case "$line" in ''|'#'*) continue ;; esac
       src="${line%%:*}"; dst="${line#*:}"
       src="${src/#\~/$HOME}"
       real="$(readlink -f -- "$src")" || {
         echo "agent-runner: manifest entry not found: $src" >&2; return 1; }
       if [ -d "$real" ]; then _AGENT_RUNNER_FLAGS+=(--copy-dir  "$real:$dst")
       else                    _AGENT_RUNNER_FLAGS+=(--copy-file "$real:$dst")
       fi
     done < "$manifest_file"
   }

   # Builds the --entrypoint wrapper for one agent: source startup.sh if
   # present, then exec the agent. codex also gets its OPENAI_API_KEY
   # auto-login, since --entrypoint replaces the image's own entrypoint outright.
   _agent_runner_wrapper() {
     local agent="$1" extra=""
     [ "$agent" = codex ] && extra='
   if [ -n "${OPENAI_API_KEY:-}" ] && ! codex login status >/dev/null 2>&1; then
     printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1 || true
   fi'
     printf '%s\n' \
   "INIT=/.msb/scripts/startup
   if [ -f \"\$INIT\" ]; then
     . \"\$INIT\" || { echo \"agent-runner: startup.sh failed (\$?)\" >&2; exit 1; }
   fi${extra}
   exec ${agent} \"\$@\""
   }

   # Each launcher forwards the API keys / tokens you've exported, plus whatever
   # ~/.agent-runner/ resolves to (see below). For another pi provider, add its
   # --env line below.
   pi-box() {
     local -a e=()
     [ -n "$ANTHROPIC_API_KEY" ]  && e+=(--env ANTHROPIC_API_KEY)
     [ -n "$OPENAI_API_KEY" ]     && e+=(--env OPENAI_API_KEY)
     [ -n "$GEMINI_API_KEY" ]     && e+=(--env GEMINI_API_KEY)
     [ -n "$OPENROUTER_API_KEY" ] && e+=(--env OPENROUTER_API_KEY)
     _agent_runner_flags || return 1
     msb run "${_REG}pi-runner" -t --pull "${_PULL:-always}" -w /workspace --volume "$PWD:/workspace" \
       --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" "${_AGENT_RUNNER_FLAGS[@]}" \
       --entrypoint /bin/sh -- -c "$(_agent_runner_wrapper pi)" agent-entry "$@"
   }

   # For your Claude subscription, run `claude setup-token` once and export the
   # CLAUDE_CODE_OAUTH_TOKEN it prints. For API billing, export ANTHROPIC_API_KEY.
   claude-box() {
     local -a e=(--env IS_SANDBOX=1)
     [ -n "$ANTHROPIC_API_KEY" ]       && e+=(--env ANTHROPIC_API_KEY)
     [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && e+=(--env CLAUDE_CODE_OAUTH_TOKEN)
     _agent_runner_flags || return 1
     msb run "${_REG}claude-runner" -t --pull "${_PULL:-always}" -w /workspace --volume "$PWD:/workspace" \
       --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" "${_AGENT_RUNNER_FLAGS[@]}" \
       --entrypoint /bin/sh -- -c "$(_agent_runner_wrapper claude)" agent-entry "$@"
   }

   codex-box() {
     local -a e=()
     [ -n "$OPENAI_API_KEY" ] && e+=(--env OPENAI_API_KEY)
     _agent_runner_flags || return 1
     msb run "${_REG}codex-runner" -t --pull "${_PULL:-always}" -w /workspace --volume "$PWD:/workspace" \
       --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" "${_AGENT_RUNNER_FLAGS[@]}" \
       --entrypoint /bin/sh -- -c "$(_agent_runner_wrapper codex)" agent-entry "$@"
   }
   ```

   Each run re-pulls `:latest`, reusing cached layers when the image is unchanged.
   The `--env` guards are required because `msb` errors on an unset variable, so
   each launcher forwards only the keys you've set. `~/.agent-runner/` (see
   "Startup script & credentials" below) is registered into the VM before
   boot, not mounted — nothing written inside the VM reaches these files. The
   `--entrypoint` override sources `startup.sh` before the agent starts; it
   replaces the image's own entrypoint, so it works the same against a stock
   image or one you built yourself.

## Use

Export the API key for the agent you want, then launch it in your project:

```bash
export ANTHROPIC_API_KEY=...      # or CLAUDE_CODE_OAUTH_TOKEN, OPENAI_API_KEY, …
cd ~/my-project
claude-box                        # or pi-box / codex-box
```

- The sandbox is **throwaway** — fresh every run, removed on exit. Your code is
  safe; it's just mounted in.
- Need more power: `CPUS=8 MEMORY=8G claude-box`.
- Pass flags straight to the agent: `codex-box --version`.

**Codex** also works with a ChatGPT subscription — with no `OPENAI_API_KEY` set,
it prompts you to sign in. **Claude** runs without per-action permission prompts
(it's sandboxed); for normal prompting use `claude-box --permission-mode default`.

## Startup script & credentials

`~/.agent-runner/` on the host holds two optional files, registered into every
sandbox before the agent starts — no image rebuild required, and this works
against the images already published to GHCR:

- **`startup.sh`** — sourced before the agent runs. Export env vars, set your
  git identity, install a package.
- **`manifest`** — a `source:destination` list, one pair per line, for files
  and directories that need to land at an exact path (git config, `gh`
  credentials, SSH keys, cloud CLI state).

```bash
mkdir -p ~/.agent-runner
touch ~/.agent-runner/startup.sh
chmod 600 ~/.agent-runner/startup.sh   # it may hold secrets
```

```sh
# ~/.agent-runner/startup.sh
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
export OPENROUTER_API_KEY=…
export GH_TOKEN=…   # `gh auth token`, or a PAT — see the note on gh below
```

```
# ~/.agent-runner/manifest
~/.gitconfig:/root/.gitconfig
```

`GH_TOKEN` is the reliable way to carry a GitHub login in: `gh` and its
git-credential helper both read it directly, and `git push` over HTTPS then
works out of the box. Copying `~/.config/gh` into `manifest` looks like it
should work too, but doesn't on a host where `gh` stores its real token in a
system keyring (the macOS default) — the config directory alone has no
credential in it, and authentication silently fails inside the sandbox. It
only carries a working login where `gh` keeps its token in plaintext (e.g.
Linux without a keyring); check with `gh auth status` — `(keyring)` in the
output means `GH_TOKEN` is the path to use.

Any other git host works the same way through a credential helper set up in
`startup.sh`. For SSH remotes, add a key to `manifest` — use a dedicated
deploy key rather than a personal one, since the agent runs without
permission prompts and can use any key copied in.

A manifest source can be a symlink (e.g. under a dotfile manager); it is
resolved to its real path before anything is copied.

## Isolation & safety

The isolation boundary is the **microsandbox microVM** — every launch runs the
agent in its own throwaway VM. Because that boundary exists, the runners turn off
the agents' in-app guardrails for a hands-off session: Claude runs in
bypass-permissions mode, Codex with full filesystem access, and the workspace is
pre-trusted. So inside the VM the agent acts without prompts.

Three things still cross the boundary: `/workspace` is a **bind mount of your
real directory** (the agent can change those files); **network egress is
open** by default; and anything named in `~/.agent-runner/manifest` or
`~/.agent-runner/startup.sh` is registered into the VM and readable by the
agent — one-directionally, so nothing the VM writes reaches these files back,
but the agent can still read and use what's there. Don't point a runner at
code you don't trust without locking those down — add msb network rules
(`--no-net`, or `--net-rule "allow@host:tcp:443"`), mount the workspace
read-only, and/or leave `~/.agent-runner/` empty.

## Build an image yourself

Prefer to build locally instead of pulling from GHCR? You need Docker. Build the
image and load it into `msb`, then run the launcher with an empty `_REG` so it
uses your local image:

```bash
docker build -t codex-runner runners/codex          # or pi / claude
docker save codex-runner | msb load --tag codex-runner

_REG="" codex-box                                    # uses the local image
```

The `Dockerfile` for each agent lives in `runners/<agent>/`.

## Add an agent

1. Add `runners/<agent>/Dockerfile`, ending in `ENTRYPOINT ["<cli>"]`. No
   entrypoint shim needed — the launcher's `--entrypoint` override handles
   `startup.sh` and any agent-specific login dance (see `codex-box`'s wrapper
   for an example).
2. Add the agent (npm package + major version) to the matrix in
   `.github/workflows/build-runners.yml`.
3. Add a `<agent>-box` launcher that forwards the env vars it needs, calls
   `_agent_runner_flags`, and passes `--entrypoint /bin/sh -- -c
   "$(_agent_runner_wrapper <agent>)" agent-entry "$@"` to `msb run`.

---

Images are built and published to GHCR by `.github/workflows/build-runners.yml`.

## License

[MIT](LICENSE)
