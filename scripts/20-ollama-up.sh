#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 20-ollama-up.sh — ensure a host Ollama server reachable from Kind pods, with
# the demo model pulled. Runs only when LLM_PROVIDER=ollama; no-op otherwise.
#
# Idempotent:
#   - reuses an already-running server if one answers on $OLLAMA_PORT
#   - otherwise starts one bound to 0.0.0.0:$OLLAMA_PORT (pid in .ollama.pid)
#   - pulls LLM_MODEL only if it is not already present
#
# This script NEVER reconfigures a system-managed Ollama. It only detects whether
# the host Ollama will be reachable from IPv4-only Kind pods and, if not, prints
# guidance. The actual pod->host reachability is the hard gate in 35-llm-config.sh.
#
# Docker Desktop + WSL2 note:
#   Kind pods are IPv4-only and reach the WSL host through the Windows loopback,
#   which the WSL2 *NAT-mode* mirror forwards ONLY for IPv4 sockets. Stock Ollama
#   binds dual-stack [::] (shown by `ss` as `*:11434`), which that mirror skips —
#   so pods cannot reach it. The clean fix that leaves Ollama untouched is WSL
#   *mirrored* networking (networkingMode=mirrored in .wslconfig + `wsl --shutdown`).
#   See docs/troubleshooting.md.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

if [ "${LLM_PROVIDER:-ollama}" != "ollama" ]; then
  log "LLM_PROVIDER=${LLM_PROVIDER:-} — Ollama not needed, skipping"
  exit 0
fi

require_cmd ollama
PORT="${OLLAMA_PORT:-11434}"
MODEL="${LLM_MODEL:-llama3.2:1b}"
PIDFILE="$REPO_ROOT/.ollama.pid"

api_up() { curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/tags" >/dev/null 2>&1; }

# bind_addr — the listen address `ss`/`lsof` reports for $PORT (e.g. 0.0.0.0,
# 127.0.0.1, * for dual-stack, [::]). Empty if it can't be determined.
bind_addr() {
  if have_cmd ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ":${PORT}$" | sed -E "s/:${PORT}$//" | head -1
  elif have_cmd lsof; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | sed -E "s/:${PORT}$//" | head -1
  fi
}

# is_ipv4_bind — true only for an explicit IPv4 listener (0.0.0.0 / 127.0.0.1).
# Dual-stack/IPv6 (* / [::]) is NOT counted: the WSL2 NAT-mode mirror skips it,
# so IPv4-only Kind pods can't reach it (unless WSL mirrored networking is on,
# which 35-llm-config.sh verifies directly from a pod).
is_ipv4_bind() {
  case "$(bind_addr)" in
    0.0.0.0|127.0.0.1) return 0 ;;
    *) return 1 ;;
  esac
}

if api_up; then
  ok "reusing existing Ollama server on :${PORT}"
else
  log "starting 'ollama serve' on 0.0.0.0:${PORT}..."
  OLLAMA_HOST="0.0.0.0:${PORT}" nohup ollama serve >"$REPO_ROOT/.ollama.log" 2>&1 &
  echo $! > "$PIDFILE"
  wait_for "ollama API on :${PORT}" 60 bash -c "curl -fsS --max-time 3 http://127.0.0.1:${PORT}/api/tags >/dev/null"
fi

# Informational reachability hint (does NOT modify Ollama, does NOT fail here).
if is_ipv4_bind; then
  ok "Ollama has an IPv4 listener on :${PORT} (reachable from Kind pods)"
else
  warn "Ollama on :${PORT} is bound dual-stack/IPv6 ('$(bind_addr):${PORT}')."
  warn "On Docker Desktop + WSL2 (NAT mode) IPv4-only Kind pods cannot reach it."
  warn "Leave Ollama as-is and enable WSL mirrored networking instead:"
  warn "  1. In Windows %UserProfile%\\.wslconfig add under [wsl2]: networkingMode=mirrored"
  warn "  2. From Windows: wsl --shutdown   (then 'make up' again)"
  warn "35-llm-config.sh will verify pod->host reachability directly. See docs/troubleshooting.md."
fi

# --- model ----------------------------------------------------------------
if OLLAMA_HOST="127.0.0.1:${PORT}" ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  ok "model '${MODEL}' already present"
else
  log "pulling model '${MODEL}' (one-time)..."
  OLLAMA_HOST="127.0.0.1:${PORT}" ollama pull "$MODEL"
  ok "model '${MODEL}' pulled"
fi

# Confirm the model can be seen via the API the cluster will use.
if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/tags" | grep -q "\"${MODEL%%:*}"; then
  ok "Ollama ready: model '${MODEL}' served on :${PORT}"
else
  warn "model '${MODEL}' not visible via API yet — check 'ollama list'"
fi
