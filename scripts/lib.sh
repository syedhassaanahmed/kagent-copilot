#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/lib.sh — shared helpers + OS-detection layer for the kagent-copilot demo.
#
# Source this from every script:
#     . "$(dirname "$0")/lib.sh"
#
# Design goals: idempotent helpers, POSIX-portable bash, and a uname-based OS
# layer so the same scripts run on Linux, WSL2 and macOS without edits.
# ---------------------------------------------------------------------------

# Resolve repo root from this file's location (scripts/ -> repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# --- PATH augmentation ----------------------------------------------------
# Tools installed for the current user (dotnet global tools like `pac`, the
# .NET host, devtunnel, Homebrew, ~/.local/bin) often live in dirs that are
# only added to PATH by an interactive shell's profile. `make` runs recipes in
# a NON-interactive bash that does not source those profiles, so `pac`/`dotnet`
# can appear "missing" there. Prepend the standard locations (when present and
# not already on PATH) so every script finds them regardless of how it's run.
_prepend_path() {
  case ":${PATH}:" in
    *":$1:"*) : ;;                  # already present
    *) [ -d "$1" ] && PATH="$1:${PATH}" ;;
  esac
}
_prepend_path "$HOME/.dotnet/tools"   # dotnet global tools: pac
_prepend_path "$HOME/.dotnet"         # dotnet host
_prepend_path "$HOME/.local/bin"      # devtunnel, pipx, etc.
_prepend_path "/home/linuxbrew/.linuxbrew/bin"
[ -d /opt/homebrew/bin ] && _prepend_path "/opt/homebrew/bin"   # Apple Silicon brew
export PATH

# --- logging -------------------------------------------------------------
_c() { [ -t 2 ] && printf '%s' "$1" || printf ''; }
log()  { printf '%s[%s]%s %s\n' "$(_c $'\033[1;34m')" "$(date +%H:%M:%S)" "$(_c $'\033[0m')" "$*" >&2; }
ok()   { printf '%s[ ok ]%s %s\n' "$(_c $'\033[1;32m')" "$(_c $'\033[0m')" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$(_c $'\033[1;33m')" "$(_c $'\033[0m')" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$(_c $'\033[1;31m')" "$(_c $'\033[0m')" "$*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- OS / arch detection -------------------------------------------------
# detect_os -> linux | wsl2 | macos | unknown
detect_os() {
  case "$(uname -s)" in
    Linux)
      if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
        echo wsl2
      else
        echo linux
      fi ;;
    Darwin) echo macos ;;
    *) echo unknown ;;
  esac
}

# detect_arch -> amd64 | arm64 | <raw>
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) uname -m ;;
  esac
}

# --- portable sed -i -----------------------------------------------------
# Usage: sed_inplace 's/old/new/' file
sed_inplace() {
  local expr="$1" file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i "$expr" "$file"        # GNU sed (Linux/WSL2)
  else
    sed -i '' "$expr" "$file"     # BSD sed (macOS)
  fi
}

# --- .env handling -------------------------------------------------------
# load_env [path] — export all KEY=VALUE pairs from .env into the environment.
load_env() {
  local f="${1:-$REPO_ROOT/.env}"
  if [ -f "$f" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
}

# upsert_env KEY VALUE [path] — write or update a KEY=VALUE line in .env.
upsert_env() {
  local key="$1" val="$2" f="${3:-$REPO_ROOT/.env}"
  touch "$f"
  if grep -qE "^${key}=" "$f"; then
    sed_inplace "s|^${key}=.*|${key}=${val}|" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >> "$f"
  fi
  ok "set ${key}=${val}"
}

# ensure_env_file — create .env from .env.example on first run.
ensure_env_file() {
  if [ ! -f "$REPO_ROOT/.env" ]; then
    cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
    warn "created .env from .env.example — review it before continuing"
  fi
}

# pac_env_url — echo the Dataverse environment URL to use with pac.
# Prefers an explicit $PAC_ENVIRONMENT_URL; otherwise falls back to the active
# pac auth profile's OrgUrl (requires an authenticated `pac` profile). Prints
# nothing and returns non-zero when it cannot be determined.
pac_env_url() {
  if [ -n "${PAC_ENVIRONMENT_URL:-}" ]; then
    printf '%s' "$PAC_ENVIRONMENT_URL"
    return 0
  fi
  have_cmd pac || return 1
  local url
  url="$(pac org who --json 2>/dev/null | sed -n 's/.*"OrgUrl":"\([^"\\]*\)".*/\1/p' | head -1)"
  [ -n "$url" ] || return 1
  printf '%s' "$url"
}

# pac_env_id — echo the Power Platform environment id (used to build Copilot
# Studio deep links). Prefers explicit env vars; otherwise derives it from the
# active pac profile's EnvironmentId. The full id is returned verbatim — in
# particular the default environment's "Default-" prefix is KEPT, because the
# Copilot Studio URL uses the whole id. Prints nothing / returns non-zero when
# it cannot be determined.
pac_env_id() {
  local id="${COPILOT_ENVIRONMENT_ID:-${POWER_PLATFORM_ENVIRONMENT_ID:-${PAC_ENVIRONMENT_ID:-}}}"
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return 0
  fi
  have_cmd pac || return 1
  id="$(pac org who --json 2>/dev/null | sed -n 's/.*"EnvironmentId":"\([^"\\]*\)".*/\1/p' | head -1)"
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# copilot_id — echo the deployed Copilot ID (GUID) for the host agent, matched
# by its display name ($1, default $COPILOT_AGENT_DISPLAY_NAME) in the given
# environment ($2, default $PAC_ENVIRONMENT_URL). `pac copilot list` exposes only
# Name + Copilot ID (no schema name), and the Copilot ID column precedes the
# Solution ID column, so the first GUID on the matching row is the one we want.
# Prints nothing if not deployed / not resolvable.
copilot_id() {
  local name="${1:-${COPILOT_AGENT_DISPLAY_NAME:-}}" env="${2:-${PAC_ENVIRONMENT_URL:-}}"
  [ -n "$name" ] || return 1
  have_cmd pac || return 1
  pac copilot list ${env:+--environment "$env"} 2>/dev/null \
    | grep -F "$name" \
    | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1
}

# find_connector_id [display] [env] — echo the custom-connector id whose
# `pac connector list` row contains the display name ($1, default
# $CONNECTOR_DISPLAY_NAME) in the environment ($2, default $PAC_ENVIRONMENT_URL).
# Prints nothing when pac/env is unavailable or no match is found. Shared by
# 60-copilot-deploy.sh (upsert) and 99-teardown.sh (cleanup).
find_connector_id() {
  local display="${1:-${CONNECTOR_DISPLAY_NAME:-}}" env="${2:-${PAC_ENVIRONMENT_URL:-}}"
  [ -n "$env" ] || return 0
  have_cmd pac || return 0
  pac connector list --environment "$env" 2>/dev/null \
    | awk -v display="$display" 'index($0, display) > 0 { print $1; exit }' || true
}

# wait_for "description" timeout_seconds cmd [args...]
# Retries cmd until it exits 0 or the timeout elapses.
wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local start now
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    now=$(date +%s)
    if [ $(( now - start )) -ge "$timeout" ]; then
      die "timed out after ${timeout}s waiting for: ${desc}"
    fi
    sleep 3
  done
  ok "ready: ${desc}"
}

# --- misc ----------------------------------------------------------------
# require_cmd cmd [hint] — die with a helpful message if a command is missing.
require_cmd() {
  have_cmd "$1" || die "required command not found: $1${2:+ ($2)}"
}

# kagent_namespace — the single Kubernetes namespace that hosts kagent AND the
# demo Agent. KAGENT_NAMESPACE is the one knob; every script resolves the
# namespace through this helper so there is exactly one source of truth.
kagent_namespace() {
  printf '%s' "${KAGENT_NAMESPACE:-kagent}"
}

# http_code URL [extra curl args...] — echo the HTTP status of a request to URL
# (000 when unreachable). curl's own '%{http_code}' write-out already yields 000
# on failure, so no '|| echo 000' doubling is needed. Pass per-call flags such as
# --max-time or -H after the URL.
http_code() {
  local url="$1"; shift
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# print_ipv4_fix_hint [port] — explain (to stderr) why a dual-stack/IPv6 Ollama is
# unreachable from IPv4-only Kind pods on Docker Desktop + WSL2, and print the
# one-time systemd drop-in that binds Ollama to IPv4. Used by 35-llm-config.sh
# when a pod cannot reach the host Ollama.
print_ipv4_fix_hint() {
  local port="${1:-${OLLAMA_PORT:-11434}}"
  local dropdir=/etc/systemd/system/ollama.service.d
  cat >&2 <<EOF
Ollama on :${port} is bound dual-stack/IPv6 ('*:${port}') — IPv4-only Kind pods
cannot reach it through the WSL2 NAT-mode mirror. Bind Ollama to IPv4 once (keeps
the default port ${port}), then re-run 'make up'. The drop-in is named
'zz-ipv4.conf' so it overrides any existing override.conf (systemd merges *.d
files alphabetically; the last assignment wins):

    sudo rm -f ${dropdir}/ipv4.conf; \\
    sudo mkdir -p ${dropdir} && \\
    printf '[Service]\\nEnvironment="OLLAMA_HOST=127.0.0.1:${port}"\\n' \\
      | sudo tee ${dropdir}/zz-ipv4.conf && \\
    sudo systemctl daemon-reload && sudo systemctl restart ollama

Verify with: ss -ltn | grep ${port}   (expect 127.0.0.1:${port}, not *:${port})
Note: OLLAMA_HOST=0.0.0.0 is NOT enough — Ollama still binds dual-stack; the fix
must pin an explicit IPv4 address (127.0.0.1).
(No-Ollama-change alternative: WSL mirrored networking — see docs/troubleshooting.md.)
EOF
}
