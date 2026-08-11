# Startup script for agent runners

Date: 2026-08-11
Status: approved design, not yet implemented

## Problem

The runners boot a throwaway microVM per launch, so there is no place to put
per-user setup. Three concrete gaps:

1. **Git identity.** `git commit` inside the sandbox fails with "Please tell me
   who you are". An earlier attempt forwarded `GIT_AUTHOR_*`/`GIT_COMMITTER_*`
   from the host (2556252, 74ac035) and was reverted; it also never addressed
   `git push`.
2. **Credentials.** API keys reach the sandbox only through per-key `--env`
   guards in each launcher, which exist because `msb` aborts on an unset
   variable. Adding a provider means editing every launcher.
3. **Extra packages.** There is no way to add a tool for one project without
   forking the image.

## Non-goals

- **No persistent volume.** Considered and rejected: mounting a named volume at
  `/root` shadows the images' baked-in seeding (`.claude.json`,
  `.claude/settings.json`, `.codex/config.toml`, `.pi/agent/settings.json`) and
  uv at `/root/.local/bin`, forcing a rewrite of all of it into runtime seeding.
  The runner also stops being throwaway, which is its main safety property.
- **No launcher-driven image build.** A hash-cached derived image was considered
  for fast package installs and rejected, to avoid making Docker a hard runtime
  dependency of the launchers. This does not touch the manual "Build an image
  yourself" route, which stays as documented.

## Concept

The host holds the truth. `msb run` patches the VM rootfs before boot via
`--copy-dir`, and the entrypoint sources what was copied in.

Key property: **`--copy-*` is one-directional.** Writes inside the VM never
reach the host file. That is what makes copying credentials in acceptable where
a bind mount was not — the README's current warning ("Do not mount
`~/.claude/.credentials.json`. Its rotating OAuth session breaks when a sandbox
writes to it") does not apply to a copy.

One host directory, `~/.agent-runner/`, shared by all three runners. It is
copied in whole; `startup.sh` inside it is the entry point, and anything else
placed alongside is available to that script by path.

```sh
# ~/.agent-runner/startup.sh   (chmod 600)
export ANTHROPIC_API_KEY=sk-ant-…
export OPENROUTER_API_KEY=…

git config --global user.name  "Your Name"
git config --global user.email "you@example.com"

apt-get install -y --no-install-recommends some-tool >/dev/null
```

## Launcher changes

Each `*-box` function gains a single guarded copy. The guard mirrors the
existing `--env` ones: `msb` errors on a missing source path.

```bash
local -a c=(); local s=""
if [ -d "$HOME/.agent-runner" ]; then
  s="$(mktemp -d)" && cp -RLp "$HOME/.agent-runner/." "$s/" || {
    echo "agent-runner: could not stage ~/.agent-runner" >&2; rm -rf "$s"; return 1; }
  c+=(--copy-dir "$s:/root/.agent-runner")
fi

msb run "${_REG}claude-runner" -t --pull "${_PULL:-always}" \
  -w /workspace --volume "$PWD:/workspace" \
  --cpus "${CPUS:-2}" --memory "${MEMORY:-1G}" "${e[@]}" "${c[@]}" -- "$@"
local rc=$?; [ -n "$s" ] && rm -rf "$s"; return $rc
```

### Why the staging copy

`msb --copy-dir` preserves symlinks instead of following them. Verified on
macOS with msb:

```console
$ mkdir -p /tmp/t && ln -sf ~/.gitconfig /tmp/t/gc
$ msb run ubuntu --copy-dir /tmp/t:/root/t -- ls -l /root/t
lrwxrwxrwx 1 root root 24 Jan  1  1970 gc -> /Users/smarti/.gitconfig
```

The link survives, its target does not exist in the VM, and every read fails
with `ENOENT`. Since the expected way to populate `~/.agent-runner/` is to
symlink existing credential files into it rather than duplicate them, an
unstaged `--copy-dir` would break the common case silently.

`cp -RLp` dereferences (`-L` follows symlinks with `-R` on both BSD/macOS and
GNU coreutils), so the VM receives real files. The source is written as
`"$HOME/.agent-runner/."` so the directory's *contents* land in the staging
root; a trailing `/*` would skip dotfiles and no trailing `/.` would nest the
result one level too deep. `mktemp -d` creates the staging directory with mode
700, and `-p` preserves mode bits — without it a copied private key can end up
world-readable, and `ssh` then refuses it as "permissions are too open". A
dangling symlink makes `cp` fail, which aborts the launch with a clear message
rather than booting a VM with a broken credential path.

Open question for the smoke test: what mode and owner `msb --copy-dir` assigns
when writing into the rootfs. If it normalises them, preserving modes during
staging does not help and the SSH-key case needs another answer. `ls -l
/root/.agent-runner` inside the VM settles it.

One directory rather than a hardcoded list of paths is deliberate. Credential
layouts differ per tool and per git host; enumerating them in the launcher means
editing three shell functions every time a new one appears. With a single copy,
the launcher never changes again — a new credential file is a symlink in the
directory and a line in `startup.sh` that points at it.

The existing `--env` guards stay, but demote from the primary credential path to
an override for CI and already-exported shells.

## Git hosts

Nothing here is GitHub-bound. The images ship `gh` and that stays, but it is a
convenience, not a dependency. Any HTTPS remote works through a credential
helper configured in `startup.sh`:

```sh
export GIT_TOKEN=…
git config --global credential.helper \
  '!f(){ echo username=oauth2; echo password=$GIT_TOKEN; };f'
```

GitHub users can instead drop their `gh` config into `~/.agent-runner/` and run
`gh auth setup-git`. GitLab, Gitea and Bitbucket work the same way via their own
tokens, or via `glab`/`tea` installed from `startup.sh`.

SSH remotes work too, by placing a key in `~/.agent-runner/`. Use a dedicated
deploy key rather than a personal key: the VM runs the agent without permission
prompts, so any key copied in is a key that unsupervised code can use.

## Entrypoint shims

`ENTRYPOINT ["claude"]` starts the agent directly — there is no login shell, so
`~/.bashrc` and `~/.profile` are never read. A shim is the only hook point.
Codex already has one (`codex-entry`); claude and pi each get an equivalent.

```sh
#!/usr/bin/env sh
INIT=/root/.agent-runner/startup.sh
if [ -f "$INIT" ]; then
  . "$INIT" || { echo "agent-runner: startup.sh failed ($?)" >&2; exit 1; }
fi
exec claude "$@"
```

Copying the directory without a `startup.sh` in it is valid — the guard skips
sourcing, and the files are still there for the agent to use.

Two decisions:

- **Sourced, not executed.** A subprocess would lose every `export`, which is
  the main thing the file is for.
- **Abort on failure.** Running the agent with a half-applied environment is
  worse than a clear error.

For codex, the source must happen **before** the existing
`codex login --with-api-key` branch, since `startup.sh` may be what exports
`OPENAI_API_KEY`.

## Cost

Nothing the agent creates survives the run, and `startup.sh` re-runs on every
launch, so whatever it does is paid for each time. That is the accepted trade
for keeping the runner throwaway.

The mechanism is agnostic about its contents: the file is sourced as-is, and
whether it installs a package, only exports a key, or does nothing is the
user's call. The existing "Build an image yourself" route
(`runners/<agent>/Dockerfile` + `msb load`) is unaffected and composes with
this — a custom image can be launched with `_REG=""` and still picks up
`startup.sh`. Neither path replaces the other.

## Security

`startup.sh` is a host file sourced as root inside a VM that runs the agent
without permission prompts. It is not agent-writable (the copy is
one-directional), which is the property that keeps this bounded.

Because the whole directory is copied, its contents are the security surface:
everything in `~/.agent-runner/` is present in the VM and reachable by the
agent. That is the intent, but it makes the directory a deliberate choice
rather than a dumping ground.

Staging dereferences symlinks, so a link to `~/.ssh/id_ed25519` puts the real
key material in the VM. The link makes that easy to forget, so the README says
it plainly. The README's "Isolation & safety" section gains
this note, plus the `chmod 600` expectation and the dedicated-key advice for
SSH.

A per-project hook (`$PWD/.agent-runner/startup.sh`) is explicitly **out of
scope**: it would auto-execute code from a checked-out repository.

## Tests

`tests/runners.bats` is a Dockerfile/README linter — it cannot boot a VM, and
`msb` is not available in CI. Coverage is therefore structural:

- every runner has an entrypoint shim, and `ENTRYPOINT` points at it
- every shim sources `/root/.agent-runner/startup.sh` guarded by an existence
  check, and aborts non-zero on failure
- the codex shim sources `startup.sh` before its `codex login` branch
- the README documents `~/.agent-runner/`, the guarded `--copy-dir`, and the
  `cp -RL` staging step
- every launcher stages through `cp -RL` rather than copying the host directory
  directly (guards against a future edit reintroducing the symlink bug)

Symlink handling is settled by the check recorded above. End-to-end behaviour
(does the staged directory arrive intact, does `git push` work through a copied
credential) still needs one manual smoke test on a host with `msb`. This is
called out rather than assumed.

## Scope

`runners/{claude,codex,pi}/Dockerfile`, `tests/runners.bats`, `README.md`.
No CI workflow change: the shims stay as heredocs, so no new file enters the
per-runner build context.
