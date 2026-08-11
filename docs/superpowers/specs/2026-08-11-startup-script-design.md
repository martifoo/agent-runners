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

- **`startup.sh`** — sourced by the entrypoint before the agent starts. Env
  vars, git identity, package installs.
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

`msb run` patches the VM rootfs before boot via `--copy-file`/`--copy-dir`, one
pair per manifest line, plus `startup.sh` itself. The copy is one-directional:
writes inside the VM never reach the host file, so copying credentials in is
safe in a way a bind mount would not be.

Nothing enters the VM beyond what `manifest` and `startup.sh` name. There is no
other file, subdirectory, or convention inside `~/.agent-runner/`.

## Launcher changes

A shared function reads `manifest` and emits the `msb` flags; each `*-box`
function calls it once.

```bash
# Defined once; called from claude-box / codex-box / pi-box.
# Emits --copy-file/--copy-dir flags, one pair per manifest line, plus
# startup.sh itself. Fails loudly if a listed source does not exist.
_agent_runner_copy_flags() {
  local -n _out=$1   # nameref: caller's array, filled in place
  _out=()
  [ -f "$HOME/.agent-runner/startup.sh" ] && _out+=(
    --copy-file "$HOME/.agent-runner/startup.sh:/root/.agent-runner/startup.sh")
  local manifest_file="$HOME/.agent-runner/manifest"
  [ -f "$manifest_file" ] || return 0
  local line src dst real
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    src="${line%%:*}"; dst="${line#*:}"
    src="${src/#\~/$HOME}"
    real="$(realpath -e -- "$src")" || {
      echo "agent-runner: manifest entry not found: $src" >&2; return 1; }
    if [ -d "$real" ]; then _out+=(--copy-dir  "$real:$dst")
    else                    _out+=(--copy-file "$real:$dst")
    fi
  done < "$manifest_file"
}

claude-box() {
  local -a e=(--env IS_SANDBOX=1) c=()
  [ -n "$ANTHROPIC_API_KEY" ]       && e+=(--env ANTHROPIC_API_KEY)
  [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && e+=(--env CLAUDE_CODE_OAUTH_TOKEN)
  _agent_runner_copy_flags c || return 1

  msb run "${_REG}claude-runner" -t --pull "${_PULL:-always}" \
    -w /workspace --volume "$PWD:/workspace" \
    --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" "${c[@]}" -- "$@"
}
```

`codex-box` and `pi-box` gain the same two lines (`local -a c=()` /
`_agent_runner_copy_flags c || return 1`) before their existing `msb run`.
Nothing is written to disk on the host beyond what is already there.

### Why per-entry resolution

`msb --copy-dir`/`--copy-file` preserve symlinks instead of following them:

```console
$ mkdir -p /tmp/t && ln -sf ~/.gitconfig /tmp/t/gc
$ msb run ubuntu --copy-dir /tmp/t:/root/t -- ls -l /root/t
lrwxrwxrwx 1 root root 24 Jan  1  1970 gc -> /Users/smarti/.gitconfig
```

The link survives, its target does not exist in the VM, and every read fails
with `ENOENT`. `realpath -e` on each manifest entry resolves this at the
source: `msb` only ever receives a path that is already real, whether the
manifest entry itself is a symlink (common under dotfile managers) or points at
one.

`realpath -e` fails on a missing or dangling path, which aborts the launch with
a clear message rather than booting a VM with a broken credential path. `-e` is
the same flag on GNU and macOS's `/usr/bin/realpath`.

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

## Entrypoint shims

`ENTRYPOINT ["claude"]` starts the agent directly — there is no login shell, so
`~/.bashrc` and `~/.profile` are never read. A shim is the hook point. Codex
already has one (`codex-entry`); claude and pi each get an equivalent.

```sh
#!/usr/bin/env sh
INIT=/root/.agent-runner/startup.sh
if [ -f "$INIT" ]; then
  . "$INIT" || { echo "agent-runner: startup.sh failed ($?)" >&2; exit 1; }
fi
exec claude "$@"
```

Files placed via `manifest` without a `startup.sh` present is valid — the
guard skips sourcing, and the files are still there at their configured
destinations for the agent to use.

- **Sourced, not executed.** A subprocess would lose every `export`, which is
  the main thing the file is for.
- **Abort on failure.** Running the agent with a half-applied environment is
  worse than a clear error.

For codex, the source happens **before** the existing
`codex login --with-api-key` branch, since `startup.sh` may be what exports
`OPENAI_API_KEY`.

## Cost

Nothing the agent creates survives the run, and `startup.sh` re-runs on every
launch, so whatever it does is paid for each time. That is the trade for
keeping the runner throwaway.

The mechanism is agnostic about its contents: the file is sourced as-is, and
whether it installs a package, only exports a key, or does nothing is the
user's call. The existing "Build an image yourself" route
(`runners/<agent>/Dockerfile` + `msb load`) composes with this — a custom image
launched with `_REG=""` still picks up `startup.sh`.

A persistent home volume and a launcher-driven derived-image build were both
considered and are out of scope: the first would end the runner's throwaway
property and shadow each image's baked-in seeding at `/root`; the second would
make Docker a hard runtime dependency of the launchers. The manual
"Build an image yourself" route stays as documented instead.

## Security

`startup.sh` is a host file sourced as root inside a VM that runs the agent
without permission prompts. It is not agent-writable, since the copy is
one-directional.

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

- every runner has an entrypoint shim, and `ENTRYPOINT` points at it
- every shim sources `/root/.agent-runner/startup.sh` guarded by an existence
  check, and aborts non-zero on failure
- the codex shim sources `startup.sh` before its `codex login` branch
- the README documents `~/.agent-runner/startup.sh`, `~/.agent-runner/manifest`,
  and its `source:destination` format
- every launcher calls the shared `_agent_runner_copy_flags` rather than
  inlining its own list-parsing loop
- `_agent_runner_copy_flags` resolves each entry through `realpath -e` before
  building `--copy-file`/`--copy-dir` flags

Not covered by CI, and needing one manual smoke test on a host with `msb`:
`realpath -e` behaving the same on the target macOS version, and a
manifest-carried credential actually authenticating (`git push`, `az`, `gh`).

## Scope

`runners/{claude,codex,pi}/Dockerfile`, `tests/runners.bats`, `README.md`.
No CI workflow change: the shims stay as heredocs, so no new file enters the
per-runner build context.
