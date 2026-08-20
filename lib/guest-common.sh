#!/usr/bin/env bash
# Sourced inside the guest by harness ensure scripts.
# shellcheck shell=bash

export PATH="/root/.grok/bin:/root/.local/bin:/usr/local/bin:${PATH}"

# Always run the official Claude installer. It is idempotent and owns
# "already latest" logic — we don't scrape version endpoints ourselves.
ensure_claude_latest() {
  if [[ "${AGR_OFFLINE:-0}" == "1" ]]; then
    command -v claude >/dev/null 2>&1 || {
      echo "agr: claude not installed and AGR_OFFLINE=1" >&2
      return 1
    }
    return 0
  fi

  echo "agr: ensuring latest Claude Code…"
  curl -fsSL https://claude.ai/install.sh | bash -s -- latest
}

# Always run the official Grok installer. Binary lands in ~/.grok/bin.
ensure_grok_latest() {
  if [[ "${AGR_OFFLINE:-0}" == "1" ]]; then
    command -v grok >/dev/null 2>&1 || {
      echo "agr: grok not installed and AGR_OFFLINE=1" >&2
      return 1
    }
    return 0
  fi

  echo "agr: ensuring latest Grok…"
  curl -fsSL https://x.ai/cli/install.sh | bash
}

# Always run the official Codex installer. Same idea as Claude.
ensure_codex_latest() {
  if [[ "${AGR_OFFLINE:-0}" == "1" ]]; then
    command -v codex >/dev/null 2>&1 || {
      echo "agr: codex not installed and AGR_OFFLINE=1" >&2
      return 1
    }
    return 0
  fi

  echo "agr: ensuring latest Codex…"
  curl -fsSL https://chatgpt.com/codex/install.sh \
    | CODEX_NON_INTERACTIVE=1 CODEX_RELEASE=latest sh
}

# npm install at the pinned major. npm + the package cache handle freshness.
# Usage: ensure_npm_latest <pkg> <major> <bin> [--ignore-scripts]
ensure_npm_latest() {
  local pkg="$1" major="$2" bin="$3"
  shift 3
  local npm_flags=()

  while (($#)); do
    case "$1" in
      --ignore-scripts) npm_flags+=(--ignore-scripts); shift ;;
      *) echo "agr: unknown ensure flag: $1" >&2; return 2 ;;
    esac
  done

  if [[ "${AGR_OFFLINE:-0}" == "1" ]]; then
    command -v "$bin" >/dev/null 2>&1 || {
      echo "agr: $bin not installed and AGR_OFFLINE=1" >&2
      return 1
    }
    return 0
  fi

  echo "agr: ensuring ${pkg}@${major}…"
  npm install -g "${npm_flags[@]}" "${pkg}@${major}"
}

# Log Codex into a file-backed auth.json when possible.
# Interactive TUI does not treat bare OPENAI_API_KEY as logged-in; credentials
# must live in auth storage. Prefer existing login (e.g. ChatGPT via auth.json).
ensure_codex_auth() {
  mkdir -p /root/.codex

  # Already authenticated (API key login, ChatGPT auth.json, etc.).
  if codex login status >/dev/null 2>&1; then
    echo "agr: codex already logged in"
    return 0
  fi

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    echo "agr: logging codex in with OPENAI_API_KEY…"
    if ! printenv OPENAI_API_KEY | codex login --with-api-key; then
      echo "agr: codex login --with-api-key failed" >&2
      return 1
    fi
    return 0
  fi

  if [[ -n "${CODEX_ACCESS_TOKEN:-}" ]]; then
    echo "agr: logging codex in with CODEX_ACCESS_TOKEN…"
    if ! printenv CODEX_ACCESS_TOKEN | codex login --with-access-token; then
      echo "agr: codex login --with-access-token failed" >&2
      return 1
    fi
    return 0
  fi

  # No credentials — Codex will show its login screen (ChatGPT browser flow).
  echo "agr: no Codex credentials; interactive login will be required" >&2
  return 0
}

# Source optional host startup script registered at /.msb/scripts/startup.
run_host_startup() {
  local init="/.msb/scripts/startup"
  if [[ -f "$init" ]]; then
    # shellcheck disable=SC1090
    . "$init" || {
      echo "agr: startup.sh failed ($?)" >&2
      return 1
    }
  fi
}
