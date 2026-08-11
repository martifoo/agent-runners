# Agent Runner Startup Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every runner (`claude`, `codex`, `pi`) a way to run host-provided
setup before the agent starts — env vars, git identity, package installs, and
credential files placed at exact paths — without any Dockerfile change and
without breaking the runner's throwaway-VM model.

**Architecture:** Two shared shell functions, defined once in `README.md` and
called from all three `*-box` launchers. `_agent_runner_flags` reads
`~/.agent-runner/manifest` (a `source:destination` list, one pair per line)
and turns each entry into a `--copy-file`/`--copy-dir` flag after resolving it
with `readlink -f`; it also emits a `--script-path` flag registering
`~/.agent-runner/startup.sh`, if present, at `/.msb/scripts/startup` inside the
guest. `_agent_runner_wrapper` builds the `sh -c` script string passed via
`msb run --entrypoint /bin/sh -- -c '<wrapper>' agent-entry "$@"`: it sources
`/.msb/scripts/startup` if present, then `exec`s the real agent with all
arguments forwarded. `--entrypoint` fully replaces the image's own entrypoint,
so this works unmodified against the images already published to GHCR — no
rebuild, no Dockerfile shim.

**Tech Stack:** POSIX-compatible shell (the launcher functions must run under
both zsh and bash, since the README installs them into either `~/.zshrc` or
`~/.bashrc`), `msb` CLI flags `--script-path`/`--copy-file`/`--copy-dir`/
`--entrypoint`, `bats` (`tests/runners.bats`, static assertions against
Dockerfile/README content — it cannot boot a VM).

**Spec:** `docs/superpowers/specs/2026-08-11-startup-script-design.md`

## Global Constraints

- Manifest format: one `source:destination` pair per line in
  `~/.agent-runner/manifest`; blank lines and lines starting with `#` are
  skipped; `~` in the source expands to `$HOME`.
- Every manifest source is resolved with `readlink -f --` before it is handed
  to `msb`, **not** `realpath -e` — macOS's stock `/usr/bin/realpath` does not
  support `-e` (verified: `illegal option -- e`), while `readlink -f` works
  identically on both BSD/macOS and GNU userlands and gives the same
  fail-on-missing-path contract.
- The shared helper that fills the flags array (`_agent_runner_flags`) uses a
  plain global array (`_AGENT_RUNNER_FLAGS`), **not** `local -n` (bash
  nameref) — verified to fail under zsh with `bad option: -n`, and these
  functions must run under zsh too.
- `startup.sh` is registered via `--script-path startup:<host path>`, landing
  at `/.msb/scripts/startup` inside the guest (on `PATH`, but referenced by
  its full path in the wrapper). It is **sourced**, never executed as a
  subprocess (a subprocess would lose every `export`).
- The `--entrypoint /bin/sh -- -c '<wrapper>' agent-entry "$@"` invocation
  shape is fixed: `agent-entry` is a throwaway `$0` placeholder so that the
  caller's real arguments land in the wrapper's `"$@"` — dropping it would
  shift every argument by one position.
- If sourcing `startup.sh` fails without calling `exit` itself (e.g. its last
  command fails), the wrapper prints `agent-runner: startup.sh failed ($?)` to
  stderr and exits 1. If `startup.sh` calls `exit N` itself, sourcing
  terminates the wrapper shell immediately with that `N` — verified: this
  still correctly prevents the agent from starting, just without the wrapper's
  own message.
- Codex's `OPENAI_API_KEY`-triggered auto-login (log in only if the key is set
  and no login exists; never overwrite an existing login) moves from the
  image's `codex-entry` shim into `_agent_runner_wrapper`'s codex-specific
  branch, placed **before** `exec codex "$@"`.
- No CI workflow change.
- Scope is exactly: `runners/codex/Dockerfile` (remove the now-redundant
  `codex-entry` shim only — `claude`/`pi` need no Dockerfile change at all),
  `tests/runners.bats`, `README.md`.
- `tests/runners.bats` cannot boot a VM (`msb` is not available in CI); its
  coverage is structural (grep-based) assertions against Dockerfile/README
  text. Run with: `bats tests/`.
- Everything in this plan except the "real credential authenticates against a
  live account" check (Task 3, Step 3) has already been verified by hand, end
  to end, with a real `msb` install under real zsh, using `ubuntu` plus
  stand-in scripts in place of the actual agent binaries. Task 3 re-runs the
  mechanism against the real images as a sanity check, not as first-time
  discovery.

---

## Task 1: README — shared functions, launcher wiring, and documentation

**Files:**
- Modify: `README.md`
- Test: `tests/runners.bats`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `_agent_runner_flags` (fills global array `_AGENT_RUNNER_FLAGS`,
  returns non-zero on a missing manifest source) and `_agent_runner_wrapper`
  (agent name in, wrapper script string out via stdout) — both are called
  the same way from Task 2's `codex-box`, which this task also writes.

- [ ] **Step 1: Write the failing tests**

Append to `tests/runners.bats` (after the existing
`"README documents the launcher functions and published images"` test):

```bash
@test "README defines the shared agent-runner functions used by every launcher" {
  grep -q '_agent_runner_flags()' "$REPO/README.md"
  grep -q '_agent_runner_wrapper()' "$REPO/README.md"
  [ "$(grep -c '_agent_runner_flags || return 1' "$REPO/README.md")" -eq 3 ]
  [ "$(grep -c '_agent_runner_wrapper ' "$REPO/README.md")" -ge 3 ]
}

@test "README's manifest resolution uses readlink -f, not realpath or a bash-only nameref" {
  grep -q 'readlink -f' "$REPO/README.md"
  ! grep -q 'realpath' "$REPO/README.md"
  ! grep -q 'local -n' "$REPO/README.md"
}

@test "README launchers override the entrypoint via --script-path/--entrypoint" {
  grep -q -- '--script-path' "$REPO/README.md"
  grep -q -- '--entrypoint /bin/sh' "$REPO/README.md"
}

@test "README documents the agent-runner manifest and startup script" {
  grep -q '.agent-runner/startup.sh' "$REPO/README.md"
  grep -q '.agent-runner/manifest' "$REPO/README.md"
  grep -qi 'source:destination' "$REPO/README.md"
}

@test "README's isolation section covers the registered-in manifest/startup.sh" {
  awk '/^## Isolation/,/^## Build an image/' "$REPO/README.md" | grep -q '.agent-runner'
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/runners.bats`
Expected: all five new tests FAIL — none of these strings exist in the
current `README.md`.

- [ ] **Step 3: Replace the launcher code block**

In the `## Setup` section, replace the fenced bash block (from `_REG="ghcr.io/martifoo/"`
through the closing `` ``` `` after `codex-box`) with (keep the existing
3-space indentation as Markdown list continuation under item "2." — the code
below is shown unindented for readability):

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

- [ ] **Step 4: Update the prose paragraph after the code block**

Replace:

```markdown
   Each run re-pulls `:latest`, reusing cached layers when the image is unchanged.
   The `--env` guards are required because `msb` errors on an unset variable, so
   each launcher forwards only the keys you've set. Credentials always travel via
   env. No host files are mounted into the throwaway VM.
```

with:

```markdown
   Each run re-pulls `:latest`, reusing cached layers when the image is unchanged.
   The `--env` guards are required because `msb` errors on an unset variable, so
   each launcher forwards only the keys you've set. `~/.agent-runner/` (see
   "Startup script & credentials" below) is registered into the VM before
   boot, not mounted — nothing written inside the VM reaches these files. The
   `--entrypoint` override sources `startup.sh` before the agent starts; it
   replaces the image's own entrypoint, so it works the same against a stock
   image or one you built yourself.
```

- [ ] **Step 5: Add the "Startup script & credentials" section**

Insert a new section directly after `## Use` and before `## Isolation & safety`:

```markdown
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
```

```
# ~/.agent-runner/manifest
~/.gitconfig:/root/.gitconfig
~/.config/gh:/root/.config/gh
```

With the `gh` line above and `gh auth setup-git` added to `startup.sh`,
`git push` works over HTTPS using your existing `gh` login. Any other git host
works the same way through a credential helper set up in `startup.sh`. For SSH
remotes, add a key to `manifest` — use a dedicated deploy key rather than a
personal one, since the agent runs without permission prompts and can use any
key copied in.

A manifest source can be a symlink (e.g. under a dotfile manager); it is
resolved to its real path before anything is copied.
```

- [ ] **Step 6: Update "Isolation & safety"**

Replace:

```markdown
Two things still cross the boundary: `/workspace` is a **bind mount of your real
directory** (the agent can change those files), and **network egress is open** by
default. Don't point a runner at code you don't trust without locking those down
— add msb network rules (`--no-net`, or `--net-rule "allow@host:tcp:443"`) and/or
mount the workspace read-only.
```

with:

```markdown
Three things still cross the boundary: `/workspace` is a **bind mount of your
real directory** (the agent can change those files); **network egress is
open** by default; and anything named in `~/.agent-runner/manifest` or
`~/.agent-runner/startup.sh` is registered into the VM and readable by the
agent — one-directionally, so nothing the VM writes reaches these files back,
but the agent can still read and use what's there. Don't point a runner at
code you don't trust without locking those down — add msb network rules
(`--no-net`, or `--net-rule "allow@host:tcp:443"`), mount the workspace
read-only, and/or leave `~/.agent-runner/` empty.
```

- [ ] **Step 7: Update "Add an agent"**

Replace:

```markdown
1. Add `runners/<agent>/Dockerfile`, ending in `ENTRYPOINT ["<cli>"]`.
2. Add the agent (npm package + major version) to the matrix in
   `.github/workflows/build-runners.yml`.
3. Add a `<agent>-box` launcher that forwards the env vars it needs.
```

with:

```markdown
1. Add `runners/<agent>/Dockerfile`, ending in `ENTRYPOINT ["<cli>"]`. No
   entrypoint shim needed — the launcher's `--entrypoint` override handles
   `startup.sh` and any agent-specific login dance (see `codex-box`'s wrapper
   for an example).
2. Add the agent (npm package + major version) to the matrix in
   `.github/workflows/build-runners.yml`.
3. Add a `<agent>-box` launcher that forwards the env vars it needs, calls
   `_agent_runner_flags`, and passes `--entrypoint /bin/sh -- -c
   "$(_agent_runner_wrapper <agent>)" agent-entry "$@"` to `msb run`.
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `bats tests/runners.bats`
Expected: all tests PASS, including all pre-existing tests and the five new
ones from this task.

- [ ] **Step 9: Commit**

```bash
git add README.md tests/runners.bats
git commit -m "feat(runners): run ~/.agent-runner/{startup.sh,manifest} via msb --entrypoint"
```

---

## Task 2: Remove codex's now-redundant entrypoint shim

**Files:**
- Modify: `runners/codex/Dockerfile`
- Modify: `tests/runners.bats`

**Interfaces:**
- Consumes: Task 1's `_agent_runner_wrapper`, whose codex branch now owns the
  `OPENAI_API_KEY` auto-login logic this task removes from the image.
- Produces: nothing consumed elsewhere; this is the last task with automated
  tests.

- [ ] **Step 1: Write the failing tests**

Replace the existing test (it asserts the shim this task deletes):

```bash
@test "codex entrypoint auto-logs-in with OPENAI_API_KEY but still allows subscription" {
  df="$REPO/runners/codex/Dockerfile"
  # Uses an entrypoint shim (not bare codex) so the key path is handled.
  grep -q 'ENTRYPOINT \["/usr/local/bin/codex-entry"\]' "$df"
  # Only logs in when a key is present AND not already logged in (don't clobber
  # a persisted subscription session); otherwise falls through to `exec codex`.
  grep -q 'OPENAI_API_KEY' "$df"
  grep -q 'codex login status' "$df"
  grep -q 'codex login --with-api-key' "$df"
  grep -q 'exec codex' "$df"
  # Never forces an auth method (subscription must still work).
  ! grep -q 'forced_login_method' "$df"
}
```

with:

```bash
@test "codex runner has a bare entrypoint; startup and login live in the launcher" {
  df="$REPO/runners/codex/Dockerfile"
  grep -q 'ENTRYPOINT \["codex"\]' "$df"
  ! grep -q 'codex-entry' "$df"
}

@test "codex's OPENAI_API_KEY auto-login lives in the README wrapper, not the image" {
  grep -q 'codex login status' "$REPO/README.md"
  grep -q 'codex login --with-api-key' "$REPO/README.md"
  # Never forces an auth method (subscription must still work).
  ! grep -q 'forced_login_method' "$REPO/README.md"
  ! grep -q 'codex-entry' "$REPO/README.md"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/runners.bats`
Expected: both new tests FAIL — `runners/codex/Dockerfile` still has the
`codex-entry` shim and its `ENTRYPOINT` still points at it.

- [ ] **Step 3: Remove the shim from `runners/codex/Dockerfile`**

Replace:

```dockerfile
# Entrypoint shim: Codex needs an auth.json, not just OPENAI_API_KEY. If the key
# is set and no login exists, log in with it. Otherwise fall through to Codex's
# ChatGPT subscription login. An existing login is never overwritten.
RUN cat > /usr/local/bin/codex-entry <<'SH'
#!/usr/bin/env sh
if [ -n "${OPENAI_API_KEY:-}" ] && ! codex login status >/dev/null 2>&1; then
  printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1 || true
fi
exec codex "$@"
SH
RUN chmod +x /usr/local/bin/codex-entry

# Disable Codex's inner bubblewrap sandbox and rely on the microVM boundary.
```

with:

```dockerfile
# Disable Codex's inner bubblewrap sandbox and rely on the microVM boundary.
```

and further down, replace:

```dockerfile
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/codex-entry"]
```

with:

```dockerfile
WORKDIR /workspace
ENTRYPOINT ["codex"]
```

(The `codex-box` launcher from Task 1 always passes its own `--entrypoint`,
so this bare entrypoint is what a stock `docker run`/`msb run` of this image
without the launcher would fall back to — matching `claude`/`pi`'s existing,
unchanged, bare entrypoints.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/runners.bats`
Expected: all tests PASS, including both new ones and everything from Task 1.

- [ ] **Step 5: Commit**

```bash
git add runners/codex/Dockerfile tests/runners.bats
git commit -m "refactor(runners): drop codex's entrypoint shim, superseded by the launcher wrapper"
```

---

## Task 3: Smoke test against the real images

Not automatable: `tests/runners.bats` is a static linter and CI has no `msb`.
The mechanism itself — `--script-path` placement, env export surviving into
`exec`, abort-on-failure in both forms, argument-boundary preservation, and
the codex login branch in both states — was already verified by hand in this
plan's design session, using `ubuntu` plus stand-in scripts in place of real
agent binaries. This task re-runs it against the real, just-changed images,
plus the one thing that couldn't be verified without a live account: a
manifest-carried credential actually authenticating.

**Files:** none (verification only).

**Interfaces:**
- Consumes: the finished Task 1 + Task 2 changes.
- Produces: confirmation (or a bug report) — nothing downstream in this repo
  depends on this task's artifacts, but the feature should not be considered
  done until it passes.

- [ ] **Step 1: Build the claude image locally**

```bash
docker build -t claude-runner runners/claude
docker save claude-runner | msb load --tag claude-runner
```

Expected: both commands succeed.

- [ ] **Step 2: Confirm the mechanism end-to-end against the real image**

```bash
mkdir -p ~/.agent-runner
printf '%s\n' 'export SMOKE_TEST_VAR=hello' > ~/.agent-runner/startup.sh
chmod 600 ~/.agent-runner/startup.sh
ln -sf ~/.gitconfig /tmp/smoke-gitconfig   # simulate a dotfile-manager symlink
printf '/tmp/smoke-gitconfig:/root/.gitconfig\n' > ~/.agent-runner/manifest
```

With the README's `_agent_runner_flags`, `_agent_runner_wrapper`, and
`claude-box` pasted into your shell, run:

```bash
_REG="" claude-box -p "run: env | grep SMOKE_TEST_VAR; cat /root/.gitconfig; echo done"
```

Expected: the agent's tool output shows `SMOKE_TEST_VAR=hello` and the real
contents of `~/.gitconfig` (not a broken symlink / `ENOENT`).

- [ ] **Step 3: Confirm `startup.sh` failure aborts the launch**

```bash
printf '%s\n' 'exit 1' > ~/.agent-runner/startup.sh
_REG="" claude-box -p "echo should not run"
echo "exit code: $?"
```

Expected: the run aborts before the agent starts; the agent's "should not
run" output does not appear.

- [ ] **Step 4: Confirm a real credential authenticates**

Using your own `gh` login (`~/.config/gh:/root/.config/gh` in `manifest`, plus
`gh auth setup-git` in `startup.sh`), run `claude-box` in a throwaway git repo
with a remote you can push to, and confirm `git push` succeeds from inside the
sandbox.

- [ ] **Step 5: Confirm codex's auto-login still works from the launcher**

Build/load `codex-runner` the same way as Step 1, then:

```bash
_REG="" OPENAI_API_KEY=sk-... codex-box login status
```

Expected: codex logs in via the key (first run) and reports logged-in status
on a second run without re-attempting login (matching the "never overwrite an
existing login" behavior this task moved out of the image).

- [ ] **Step 6: Clean up**

```bash
rm -f ~/.agent-runner/startup.sh ~/.agent-runner/manifest /tmp/smoke-gitconfig
```

Restore your real `startup.sh`/`manifest` afterward if you had any before this
smoke test.

- [ ] **Step 7: Record the result**

No commit for this task (verification only). If any step fails, file it as a
follow-up bug against Task 1/2 rather than editing code in this task.
