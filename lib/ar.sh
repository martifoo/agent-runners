#!/usr/bin/env bash
# Host-side library for ar.
# shellcheck shell=bash

# Resolve the repo root from this file's location.
ar_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$here/.." && pwd
}

AR_ROOT="${AR_ROOT:-$(ar_root)}"
AR_SNAPSHOT_NAME="${AR_SNAPSHOT_NAME:-ar-base}"
AR_BASE_IMAGE="${AR_BASE_IMAGE:-node:24-bookworm}"
AR_NPM_VOLUME="${AR_NPM_VOLUME:-ar-npm}"
AR_HOME_VOLUME="${AR_HOME_VOLUME:-ar-home}"
AR_CODEX_HOME_VOLUME="${AR_CODEX_HOME_VOLUME:-ar-codex-home}"
AR_GROK_HOME_VOLUME="${AR_GROK_HOME_VOLUME:-ar-grok-home}"
AR_CONFIG_DIR="${AR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ar}"

# Ensure a named volume exists (best-effort).
ar_ensure_volume() {
  local vol="$1"
  if msb volume list 2>/dev/null | grep -qE "(^|[[:space:]])${vol}([[:space:]]|$)"; then
    return 0
  fi
  msb volume create "$vol" >/dev/null 2>&1 || true
}

ar_ensure_volumes() {
  ar_ensure_volume "$AR_NPM_VOLUME"
  ar_ensure_volume "$AR_HOME_VOLUME"
  ar_ensure_volume "$AR_CODEX_HOME_VOLUME"
  ar_ensure_volume "$AR_GROK_HOME_VOLUME"
}

# Warn when a secrets-bearing file is group/world-readable.
ar_warn_insecure_perms() {
  local path="$1" mode
  [[ -e "$path" ]] || return 0
  # macOS: %Lp → 644; Linux: %a → 644 (sometimes 0644)
  mode="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || true)"
  [[ -n "$mode" ]] || return 0
  # Permissions are octal (e.g. 600, 644).
  mode=$((8#$mode))
  mode=$((mode & 0777))
  if (( mode & 0077 )); then
    printf 'ar: warning: %s should be chmod 600 (currently %03o)\n' "$path" "$mode" >&2
  fi
}

# Parse ~/.config/ar/.env into AR_DOTENV_FLAGS as --env KEY=VALUE pairs.
# dotenv format only (KEY=value); not a shell script.
ar_load_dotenv() {
  AR_DOTENV_FLAGS=()
  local envfile="${AR_CONFIG_DIR}/.env"
  local line key val

  [[ -f "$envfile" ]] || return 0
  ar_warn_insecure_perms "$envfile"

  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == export[[:space:]]* ]] && line="${line#export}"
    line="${line#"${line%%[![:space:]]*}"}"

    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # strip one layer of matching quotes
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      AR_DOTENV_FLAGS+=(--env "${key}=${val}")
    else
      echo "ar: ignoring invalid .env line: $line" >&2
    fi
  done < "$envfile"
}

# Build flags for $AR_CONFIG_DIR/{startup.sh,manifest}.
# Fills AR_USER_FLAGS array.
ar_user_flags() {
  AR_USER_FLAGS=()
  local startup manifest_file line src dst real

  startup="${AR_CONFIG_DIR}/startup.sh"
  if [[ -f "$startup" ]]; then
    ar_warn_insecure_perms "$startup"
    AR_USER_FLAGS+=(--script-path "startup:$startup")
  fi

  manifest_file="${AR_CONFIG_DIR}/manifest"
  [[ -f "$manifest_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|'#'*) continue ;; esac
    src="${line%%:*}"
    dst="${line#*:}"
    src="${src/#\~/$HOME}"
    if command -v readlink >/dev/null 2>&1; then
      real="$(readlink -f -- "$src" 2>/dev/null || true)"
    else
      real=""
    fi
    if [[ -z "$real" ]]; then
      echo "ar: manifest entry not found: $src" >&2
      return 1
    fi
    if [[ -d "$real" ]]; then
      AR_USER_FLAGS+=(--copy-dir "$real:$dst")
    else
      AR_USER_FLAGS+=(--copy-file "$real:$dst")
    fi
  done < "$manifest_file"
}

# True if the named snapshot exists.
ar_snapshot_exists() {
  msb snapshot list 2>/dev/null | grep -qE "(^|[[:space:]])${AR_SNAPSHOT_NAME}([[:space:]]|$)"
}

# Provision base tools and create/replace the snapshot.
ar_build_base() {
  local name="ar-base-build-$$"
  local provision="$AR_ROOT/base/provision.sh"
  local cpus="${CPUS:-${MSB_CPUS:-2}}"
  local memory="${MEMORY:-${MSB_MEMORY:-2G}}"

  [[ -f "$provision" ]] || {
    echo "ar: missing $provision" >&2
    return 1
  }

  echo "ar: provisioning base from ${AR_BASE_IMAGE}…"
  # Run provision non-interactively; sandbox stops when the command exits.
  msb run "$AR_BASE_IMAGE" \
    --name "$name" \
    --replace \
    --cpus "$cpus" \
    --memory "$memory" \
    --script-path "provision:$provision" \
    --no-tty \
    -- bash /.msb/scripts/provision

  echo "ar: creating snapshot ${AR_SNAPSHOT_NAME}…"
  msb snapshot create --from "$name" "$AR_SNAPSHOT_NAME" --force
  msb remove "$name" >/dev/null 2>&1 || true
  echo "ar: base snapshot ready (${AR_SNAPSHOT_NAME})"
}

# Run a harness against $PWD.
# Usage: ar_run <claude|codex|pi> [agent args…]
ar_run() {
  local harness="${1:?harness required}"
  shift

  local ensure="$AR_ROOT/harnesses/${harness}/ensure.sh"
  local common="$AR_ROOT/lib/guest-common.sh"
  local cpus="${CPUS:-${MSB_CPUS:-2}}"
  local memory="${MEMORY:-${MSB_MEMORY:-2G}}"
  local name offline=0
  local -a extra_env=()

  [[ -f "$ensure" ]] || {
    echo "ar: unknown harness: $harness" >&2
    return 1
  }
  [[ -f "$common" ]] || {
    echo "ar: missing $common" >&2
    return 1
  }

  # Host-side flags consumed before agent args.
  while (($#)); do
    case "$1" in
      --rebuild-base)
        ar_build_base
        shift
        ;;
      --offline)
        offline=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        # Unknown host flag → treat as agent arg (and rest).
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if ! ar_snapshot_exists; then
    echo "ar: base snapshot missing — building once…"
    ar_build_base
  fi

  ar_ensure_volumes
  ar_load_dotenv || return 1
  ar_user_flags || return 1

  case "$harness" in
    claude) extra_env+=(--env IS_SANDBOX=1) ;;
  esac

  # Optional offline mode for the guest ensure step.
  if ((offline)); then
    extra_env+=(--env AR_OFFLINE=1)
  fi

  # Terminal color capability for TUIs inside the microVM (Grok, etc.).
  # msb does not always inherit these; without them themes quantize badly.
  extra_env+=(--env "TERM=${TERM:-xterm-256color}")
  extra_env+=(--env "COLORTERM=${COLORTERM:-truecolor}")

  # Pass through common provider keys when already set on the host shell.
  # Prefer ~/.config/ar/.env for secrets; these are convenience overrides.
  local key
  for key in \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
    OPENAI_API_KEY CODEX_ACCESS_TOKEN \
    XAI_API_KEY GROK_DEPLOYMENT_KEY \
    GROK_THEME GROK_APPEARANCE \
    OPENROUTER_API_KEY GH_TOKEN; do
    if [[ -n "${!key:-}" ]]; then
      extra_env+=(--env "$key")
    fi
  done

  # .env values win over ambient host env when both define the same key:
  # append dotenv last so msb's last-write / guest env sees them. If msb
  # keeps first-wins instead, dotenv still covers keys not in the shell.
  if ((${#AR_DOTENV_FLAGS[@]})); then
    extra_env+=("${AR_DOTENV_FLAGS[@]}")
  fi

  name="ar-${harness}-$(basename "$PWD" | tr -c 'a-zA-Z0-9._-' '-' | sed 's/-$//')"
  # Keep name length reasonable for msb.
  name="${name:0:80}"

  local -a cmd=(
    msb run
    --from-snapshot "$AR_SNAPSHOT_NAME"
    --name "$name"
    --replace
    -t
    -w /workspace
    --volume "$PWD:/workspace"
    --mount-named "${AR_NPM_VOLUME}:/root/.npm"
    --mount-named "${AR_HOME_VOLUME}:/root/.local"
    --mount-named "${AR_CODEX_HOME_VOLUME}:/root/.codex"
    --mount-named "${AR_GROK_HOME_VOLUME}:/root/.grok"
    --cpus "$cpus"
    --memory "$memory"
    --script-path "guest-common:$common"
    --script-path "ensure:$ensure"
  )

  if ((${#extra_env[@]})); then
    cmd+=("${extra_env[@]}")
  fi
  if ((${#AR_USER_FLAGS[@]})); then
    cmd+=("${AR_USER_FLAGS[@]}")
  fi

  cmd+=(-- bash /.msb/scripts/ensure "$@")
  exec "${cmd[@]}"
}
