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

   # Each launcher forwards the API keys / tokens you've exported. For another pi
   # provider, add its --env line below.
   pi-box() {
     local -a e=()
     [ -n "$ANTHROPIC_API_KEY" ]  && e+=(--env ANTHROPIC_API_KEY)
     [ -n "$OPENAI_API_KEY" ]     && e+=(--env OPENAI_API_KEY)
     [ -n "$GEMINI_API_KEY" ]     && e+=(--env GEMINI_API_KEY)
     [ -n "$OPENROUTER_API_KEY" ] && e+=(--env OPENROUTER_API_KEY)
     msb run "${_REG}pi-runner" -t --pull "${_PULL:-always}" -w /workspace --volume "$PWD:/workspace" \
       --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" -- "$@"
   }

   # For your Claude subscription, run `claude setup-token` once and export the
   # CLAUDE_CODE_OAUTH_TOKEN it prints. For API billing, export ANTHROPIC_API_KEY.
   # Do not mount ~/.claude/.credentials.json. Its rotating OAuth session breaks
   # when a sandbox writes to it.
   claude-box() {
     local -a e=(--env IS_SANDBOX=1)
     [ -n "$ANTHROPIC_API_KEY" ]       && e+=(--env ANTHROPIC_API_KEY)
     [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && e+=(--env CLAUDE_CODE_OAUTH_TOKEN)
     msb run "${_REG}claude-runner" -t --pull "${_PULL:-always}" -w /workspace --volume "$PWD:/workspace" \
       --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" -- "$@"
   }

   codex-box() {
     local -a e=()
     [ -n "$OPENAI_API_KEY" ] && e+=(--env OPENAI_API_KEY)
     msb run "${_REG}codex-runner" -t --pull "${_PULL:-always}" -w /workspace --volume "$PWD:/workspace" \
       --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" -- "$@"
   }
   ```

   Each run re-pulls `:latest`, reusing cached layers when the image is unchanged.
   The `--env` guards are required because `msb` errors on an unset variable, so
   each launcher forwards only the keys you've set. Credentials always travel via
   env. No host files are mounted into the throwaway VM.

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

## Isolation & safety

The isolation boundary is the **microsandbox microVM** — every launch runs the
agent in its own throwaway VM. Because that boundary exists, the runners turn off
the agents' in-app guardrails for a hands-off session: Claude runs in
bypass-permissions mode, Codex with full filesystem access, and the workspace is
pre-trusted. So inside the VM the agent acts without prompts.

Two things still cross the boundary: `/workspace` is a **bind mount of your real
directory** (the agent can change those files), and **network egress is open** by
default. Don't point a runner at code you don't trust without locking those down
— add msb network rules (`--no-net`, or `--net-rule "allow@host:tcp:443"`) and/or
mount the workspace read-only.

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

1. Add `runners/<agent>/Dockerfile`, ending in `ENTRYPOINT ["<cli>"]`.
2. Add the agent (npm package + major version) to the matrix in
   `.github/workflows/build-runners.yml`.
3. Add a `<agent>-box` launcher that forwards the env vars it needs.

---

Images are built and published to GHCR by `.github/workflows/build-runners.yml`.

## License

[MIT](LICENSE)
