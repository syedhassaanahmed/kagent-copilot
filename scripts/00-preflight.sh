#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00-preflight.sh — detect OS/arch and verify the host can run the demo.
# Idempotent: only inspects the environment, changes nothing. Exits 0 when ok.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"

OS="$(detect_os)"
ARCH="$(detect_arch)"
log "host: OS=${OS} ARCH=${ARCH} ($(uname -srm))"

# --- supported platform ---------------------------------------------------
case "$OS" in
  linux|wsl2|macos) : ;;
  *) die "unsupported platform '$OS'. Supported: Linux, WSL2, macOS. Native Windows (non-WSL) is out of scope." ;;
esac

# --- baseline commands ----------------------------------------------------
# These must exist now; kubectl/kind/helm/ollama are installed by 'make tools'.
for c in docker curl bash; do
  require_cmd "$c"
done
ok "baseline commands present: docker, curl, bash"

# --- docker runtime -------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
  case "$OS" in
    macos) die "Docker is not responding. Start Docker Desktop and retry." ;;
    *)     die "Docker daemon is not responding. Start Docker Engine (e.g. 'sudo service docker start') and retry." ;;
  esac
fi
ok "docker daemon is responding ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"

# --- resources (best-effort, warn-only) -----------------------------------
mem_gb=""
cpus=""
case "$OS" in
  macos)
    mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    cpus=$(sysctl -n hw.ncpu 2>/dev/null || echo "?") ;;
  *)
    if [ -r /proc/meminfo ]; then
      mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
    fi
    cpus=$(nproc 2>/dev/null || echo "?") ;;
esac
[ -n "$mem_gb" ] && log "resources: ${mem_gb} GB RAM, ${cpus} CPUs"
if [ -n "$mem_gb" ] && [ "$mem_gb" -lt 4 ] 2>/dev/null; then
  warn "less than 4 GB RAM detected — Kind + kagent + a local model may be tight"
fi

# --- docker compose (v2 plugin) ------------------------------------------
if docker compose version >/dev/null 2>&1; then
  ok "docker compose v2 available"
else
  warn "'docker compose' (v2 plugin) not found — needed for the n8n step"
fi

ok "preflight passed for ${OS}/${ARCH}"
