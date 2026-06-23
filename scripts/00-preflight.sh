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
  warn "'docker compose' (v2 plugin) not found — only needed for legacy cleanup paths"
fi

# --- Copilot Studio / Dev Tunnels prerequisites (warn-only) ---------------
# These power the cloud side of the demo (Copilot Studio agent <-> kagent over
# A2A through a Dev Tunnel). They are NOT required to bring up kagent locally,
# so missing tools/logins only warn here — 'make tools' installs the CLIs and
# the devtunnel/copilot scripts perform interactive login on first run.
load_env >/dev/null 2>&1 || true

# devtunnel — exposes the local kagent A2A endpoint publicly.
if have_cmd devtunnel; then
  ok "devtunnel present ($(devtunnel --version 2>/dev/null | head -1 || echo '?'))"
  if devtunnel user show >/dev/null 2>&1; then
    ok "devtunnel: logged in"
  else
    warn "devtunnel: not logged in — '25-devtunnel-up.sh' will prompt 'devtunnel user login'"
  fi
else
  warn "devtunnel not found — run 'make tools' (needed to expose kagent for Copilot Studio)"
fi

# pac — Power Platform CLI, deploys/publishes the Copilot Studio host agent.
if have_cmd pac; then
  ok "pac present ($(pac --version 2>/dev/null | grep -oE 'Version: [0-9.]+' | head -1 || echo '?'))"
  if pac auth list >/dev/null 2>&1 && pac auth list 2>/dev/null | grep -q '\*'; then
    ok "pac: an authenticated profile is selected"
  else
    warn "pac: no active auth profile — '60-copilot-deploy.sh' runs 'pac auth create' against PAC_ENVIRONMENT_URL"
  fi
else
  warn "pac not found — run 'make tools' (needed to deploy the Copilot Studio agent)"
fi

# PAC_ENVIRONMENT_URL — Dataverse environment the host agent deploys into.
if [ -n "${PAC_ENVIRONMENT_URL:-}" ]; then
  ok "PAC_ENVIRONMENT_URL set (${PAC_ENVIRONMENT_URL})"
elif derived="$(pac_env_url 2>/dev/null)" && [ -n "$derived" ]; then
  ok "PAC_ENVIRONMENT_URL not set — will auto-use the active pac profile (${derived})"
else
  warn "PAC_ENVIRONMENT_URL not set and no active pac profile — set it in .env (see 'pac org list') before 'make copilot'"
fi

ok "preflight passed for ${OS}/${ARCH}"
