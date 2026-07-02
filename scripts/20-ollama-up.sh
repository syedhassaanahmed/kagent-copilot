#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 20-ollama-up.sh — start the host Ollama server and pull the demo model.
# Runs only when LLM_PROVIDER=ollama; no-op otherwise. Idempotent:
#   - reuses an already-running server if one answers on $OLLAMA_PORT
#   - otherwise starts one bound to 127.0.0.1:$OLLAMA_PORT (log in .ollama.log)
#   - pulls LLM_MODEL only if missing
#
# Binding 127.0.0.1 gives a true IPv4 socket, which matters on Docker Desktop +
# WSL2: IPv4-only Kind pods reach the WSL host through the Windows loopback, which
# the WSL2 NAT-mode mirror forwards ONLY for IPv4 sockets (stock Ollama otherwise
# binds dual-stack [::], which pods cannot reach). Whether a pod can actually
# reach this server is verified authoritatively by 35-llm-config.sh, which prints
# the one-time IPv4 fix if a pre-existing server is bound dual-stack.
# See docs/troubleshooting.md.
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
MODEL="${LLM_MODEL:-qwen2.5:1.5b}"

api_up() { curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/tags" >/dev/null 2>&1; }

if api_up; then
  ok "reusing existing Ollama server on :${PORT}"
else
  log "starting 'ollama serve' on 127.0.0.1:${PORT} (IPv4)..."
  OLLAMA_HOST="127.0.0.1:${PORT}" nohup ollama serve >"$REPO_ROOT/.ollama.log" 2>&1 &
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
