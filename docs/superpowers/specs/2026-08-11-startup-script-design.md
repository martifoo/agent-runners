# Startup script for agent runners

Date: 2026-08-11
Status: approved design, not yet implemented

## Problem

Each runner boots a throwaway microVM per launch, so there is no place for
per-user setup to persist. Concretely:

1. `git commit` inside the sandbox fails with "Please tell me who you are",
   and there is no way to push.
2. Credentials reach the sandbox only through per-key `--env` guards in each
   launcher. Adding a provider means editing every launcher.
3. There is no way to add a tool for one project without forking the image.

## Concept

`~/.agent-runner/` on the host holds two files:

- **`startup.sh`** — sourced before the agent starts. Env vars, git identity,
  package installs.
- **`manifest`** — a `source:destination` list, one pair per line. Each line
  names a host path and the exact path it lands at inside the VM.

```
# ~/.agent-runner/manifest
~/.gitconfig:/root/.gitconfig
~/.config/gh:/root/.config/gh
~/.azure:/root/.azure
~/.ssh/deploy_key:/root/.ssh/id_ed25519
```

```sh
# ~/.agent-runner/startup.sh   (chmod 600)
export ANTHROPIC_API_KEY=sk-ant-…
export OPENROUTER_API_KEY=…

git config --global user.name  "Your Name"
git config --global user.email "you@example.com"

apt-get install -y --no-install-recommends some-tool >/dev/null
```

The entire mechanism lives in the host launcher functions — no image change,
no rebuild. `msb run` supports this directly:

- **`--script-path NAME:PATH`** registers a host file as an executable script
  at `/.msb/scripts/NAME` inside the guest, before boot.
- **`--copy-file`/`--copy-dir SRC:DST`** patches a host file or directory into
  the guest rootfs before boot, at an exact destination path.
- **`--entrypoint`** overrides the image's entrypoint outright.

The launcher passes `startup.sh` via `--script-path`, each manifest line via
`--copy-file`/`--copy-dir`, and overrides the entrypoint with a small inline
`sh -c` wrapper that sources the script (if present) and then execs the real
agent binary, forwarding all arguments. This works unmodified against the
already-published images.

All of this is one-directional: writes inside the VM never reach the host
file, so copying credentials in is safe in a way a bind mount would not be.
Nothing enters the VM beyond what `manifest` and `startup.sh` name.

## Launcher changes

Two shared functions, called from all three `*-box` functions.

```bash
# Fills the global array _AGENT_RUNNER_FLAGS with --script-path (for
# startup.sh) and --copy-file/--copy-dir (one pair per manifest line).
# A plain global, not a nameref return (bash's nameref-local flag) — that syntax is
# bash-only and this code must also run under zsh, since the README installs
# it into either ~/.zshrc or ~/.bashrc. Fails loudly if a listed source does
# not exist.
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

# Prints the --entrypoint wrapper body for one agent. codex additionally
# needs its OPENAI_API_KEY auto-login, which used to live baked into its
# image; it now lives here, since --entrypoint replaces the image's own
# entrypoint outright.
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

claude-box() {
  local -a e=(--env IS_SANDBOX=1)
  [ -n "$ANTHROPIC_API_KEY" ]       && e+=(--env ANTHROPIC_API_KEY)
  [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && e+=(--env CLAUDE_CODE_OAUTH_TOKEN)
  _agent_runner_flags || return 1

  msb run "${_REG}claude-runner" -t --pull "${_PULL:-always}" \
    -w /workspace --volume "$PWD:/workspace" \
    --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" "${_AGENT_RUNNER_FLAGS[@]}" \
    --entrypoint /bin/sh -- -c "$(_agent_runner_wrapper claude)" agent-entry "$@"
}
```

`codex-box` and `pi-box` follow the same shape: call `_agent_runner_flags`,
then pass `"${_AGENT_RUNNER_FLAGS[@]}"` plus `--entrypoint /bin/sh -- -c
"$(_agent_runner_wrapper codex)" agent-entry "$@"` (or `pi`) to their existing
`msb run`. `agent-entry` is a throwaway `$0` placeholder — `sh -c 'script' $0
$1 $2...` needs one positional before the args that are meant to reach the
script's `"$@"`.

### Why `readlink -f`, not `realpath -e`

The original design used `realpath -e`. On this project's actual target
(macOS, launchers pasted into `~/.zshrc`), that is wrong on two counts, both
found by testing on a real machine rather than assumed from general
knowledge:

- macOS's `/usr/bin/realpath` is the BSD variant and does not support `-e` —
  it errors with `illegal option -- e`. `readlink -f` is present on both BSD
  and GNU userlands, resolves symlinks the same way, and fails (exit 1, no
  output) on a missing or dangling path — the same contract `-e` would have
  given.
- `msb --copy-dir`/`--copy-file` preserve symlinks instead of following them
  (confirmed: copying a directory containing a symlink into a guest leaves a
  dangling link whose target doesn't exist there). Resolving each manifest
  entry with `readlink -f` before it reaches `msb` sidesteps this — `msb` only
  ever receives a path that is already real, whether the manifest entry
  itself is a symlink (common under dotfile managers) or points at one.

### Why a global array, not a nameref

The launcher functions are pasted into `~/.zshrc` or `~/.bashrc`, so they run
under zsh as often as bash. `local -n` (bash's nameref, the usual way to have
a helper function fill a caller-supplied array) is bash-only; under zsh it
fails immediately with `bad option: -n`. `_agent_runner_flags` instead fills
one well-known global array, `_AGENT_RUNNER_FLAGS`, which both shells support
identically.

### Why `--entrypoint` instead of a Dockerfile shim

An earlier version of this design baked a `claude-entry`/`codex-entry`/
`pi-entry` shim into each image, sourcing `startup.sh` before `exec`-ing the
agent, with `ENTRYPOINT` pointed at the shim. `msb run --entrypoint` replaces
that outright: the launcher can override the image's entrypoint at the CLI
level, so the exact same "source, then exec" wrapper can be supplied inline,
per invocation, with no image change. Verified end-to-end on a real machine:
`--script-path` places the file, sourcing it inside an `--entrypoint /bin/sh
-c '...'` wrapper makes its exports visible to the final `exec`, a failing
script aborts before that `exec` runs, and arguments containing spaces
(`-p "hello world"`) survive the `sh -c 'script' $0 "$@"` hop intact.

This also means the mechanism works against images that are already published
— no waiting on a CI rebuild — and `runners/codex/Dockerfile`'s existing
`codex-entry` shim becomes redundant. It is removed; see Scope.

The existing `--env` guards stay, as an override for CI and already-exported
shells.

## Git hosts

The images ship `gh`, but nothing here is GitHub-specific. Any HTTPS remote
works through a credential helper configured in `startup.sh`:

```sh
export GIT_TOKEN=…
git config --global credential.helper \
  '!f(){ echo username=oauth2; echo password=$GIT_TOKEN; };f'
```

GitHub users can instead add their `gh` config directory to `manifest`:

```
~/.config/gh:/root/.config/gh
```

and run `gh auth setup-git` from `startup.sh`. GitLab, Gitea and Bitbucket work
the same way via their own tokens, or via `glab`/`tea` installed from
`startup.sh`.

SSH remotes work by adding a key to `manifest`. Use a dedicated deploy key
rather than a personal key: the VM runs the agent without permission prompts,
so any key copied in is a key that unsupervised code can use.

## Worked example: Azure CLI

`az` reads credentials only from `~/.azure/`, not from an arbitrary path, so
it needs one of the two paths below.

**Service principal** — env vars only, no manifest entry:

```sh
export AZURE_CLIENT_ID=…
export AZURE_CLIENT_SECRET=…
export AZURE_TENANT_ID=…
az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" \
  --tenant "$AZURE_TENANT_ID" >/dev/null
```

**An existing `az login` session** — `~/.azure/` holds `azureProfile.json`
(account/subscriptions), `msal_token_cache.json` (the token cache),
`clouds.config` and `config`. One manifest line places the whole directory at
the exact path `az` expects:

```
~/.azure:/root/.azure
```

The general rule: any tool with a fixed config path (`az`, `gh`, `kubectl`'s
kubeconfig, SSH) needs one manifest line per path. Tools that accept a
non-interactive login via environment variables need none.

## Cost

Nothing the agent creates survives the run, and `startup.sh` re-runs on every
launch, so whatever it does is paid for each time. That is the trade for
keeping the runner throwaway.

The mechanism is agnostic about its contents: the file is sourced as-is, and
whether it installs a package, only exports a key, or does nothing is the
user's call. The existing "Build an image yourself" route
(`runners/<agent>/Dockerfile` + `msb load`) composes with this — a custom
image launched with `_REG=""` still picks up `startup.sh`, since the wrapper
comes from the launcher, not the image.

A persistent home volume and a launcher-driven derived-image build were both
considered and are out of scope: the first would end the runner's throwaway
property and shadow each image's baked-in seeding at `/root`; the second would
make Docker a hard runtime dependency of the launchers. The manual
"Build an image yourself" route stays as documented instead.

## Security

`startup.sh` is a host file, registered via `--script-path` and sourced as
root inside a VM that runs the agent without permission prompts. It is not
agent-writable: `--script-path` and `--copy-file`/`--copy-dir` all patch the
rootfs before boot, one-directionally.

The security surface is exactly `manifest` plus `startup.sh`: nothing enters
the VM that isn't named in one of the two.

Resolution is always real-file, never a symlink: a manifest entry pointing at
`~/.ssh/id_ed25519` puts the real key material in the VM. The README's
"Isolation & safety" section gets a note to that effect, plus the `chmod 600`
expectation for `startup.sh` and the dedicated-key advice for SSH.

A per-project hook (`$PWD/.agent-runner/startup.sh`) is explicitly out of
scope: it would auto-execute code from a checked-out repository.

## Tests

`tests/runners.bats` is a Dockerfile/README linter — it cannot boot a VM, and
`msb` is not available in CI. Coverage is structural:

- the README defines both `_agent_runner_flags` and `_agent_runner_wrapper`,
  and all three `*-box` functions call both
- `_agent_runner_flags` resolves manifest entries with `readlink -f`, not
  `realpath`/`local -n` (the two constructs found not to work on the actual
  target: macOS's BSD `realpath` and zsh, respectively)
- `_agent_runner_wrapper` sources `/.msb/scripts/startup` guarded by an
  existence check and aborts non-zero on failure
- the codex branch of `_agent_runner_wrapper` places the `OPENAI_API_KEY`
  login check before `exec codex "$@"`
- `runners/codex/Dockerfile` no longer defines `codex-entry`; its
  `ENTRYPOINT` is the bare `["codex"]`, matching `claude`/`pi`

Verified by hand already, on a real machine, under zsh (not assumed): every
one of the mechanisms above — `--script-path` placement, env export surviving
the `sh -c` hop into `exec`, abort-on-failure in both its forms (explicit
`exit N` inside the sourced script vs. falling off the end with a failing last
command), argument boundaries surviving `sh -c 'script' $0 "$@"` intact
(`-p "hello world"` arrives as one argument), and the codex login branch in
both its states (key set + not logged in vs. already logged in). Still needing
a manual check on a real host: a `manifest`-carried credential actually
authenticating against a live host (`git push`, `az`, `gh`), since that
depends on account state this session doesn't have.

## Scope

`runners/codex/Dockerfile` (remove the now-redundant `codex-entry` shim;
`claude`/`pi` need no Dockerfile change at all), `tests/runners.bats`,
`README.md`. No CI workflow change.
