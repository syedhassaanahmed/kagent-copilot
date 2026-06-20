#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 20-ollama-up.sh — ensure a host Ollama server reachable from Kind pods, with
# the demo model pulled. Runs only when LLM_PROVIDER=ollama; no-op otherwise.
#
# Idempotent:
#   - reuses an already-running server if it listens on all interfaces
#   - starts one bound to 0.0.0.0:$OLLAMA_PORT otherwise (pid in .ollama.pid)
#   - pulls LLM_MODEL only if it is not already present
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

# Best-effort check that the listener is on all interfaces (not loopback-only),
# so Kind pods reaching the host IP can connect.
listens_all_ifaces() {
  if have_cmd ss; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(^0\.0\.0\.0|^\*|^\[::\]|^::):${PORT}$"
  elif have_cmd lsof; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | grep -qE '(\*|0\.0\.0\.0):'"${PORT}"
  else
    return 0   # can't tell; assume ok
  fi
}

if api_up; then
  if listens_all_ifaces; then
    ok "reusing existing Ollama server on 0.0.0.0:${PORT}"
  else
    warn "an Ollama server is running but appears bound to loopback only."
    warn "Kind pods will not reach it. Stop it and re-run, or start it with"
    warn "  OLLAMA_HOST=0.0.0.0:${PORT} ollama serve"
  fi
else
  log "starting 'ollama serve' on 0.0.0.0:${PORT}..."
  OLLAMA_HOST="0.0.0.0:${PORT}" nohup ollama serve >"$REPO_ROOT/.ollama.log" 2>&1 &
  echo $! > "$PIDFILE"
  wait_for "ollama API on :${PORT}" 60 bash -c "curl -fsS --max-time 3 http://127.0.0.1:${PORT}/api/tags >/dev/null"
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
