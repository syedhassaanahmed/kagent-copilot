#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 99-teardown.sh — tear the demo down. Idempotent: missing pieces are skipped.
#
# Removes (in reverse order of creation):
#   - n8n Docker Compose stack
#   - Kind cluster (which removes kagent + all CRs)
# Optionally stops Ollama / removes the model when called with flags.
#
# Usage:
#   99-teardown.sh                 # remove cluster + n8n (default)
#   99-teardown.sh --stop-ollama   # also stop the ollama serve we started
#   99-teardown.sh --rm-model      # also remove the pulled model
#   99-teardown.sh --all           # everything above
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env

STOP_OLLAMA=0
RM_MODEL=0
for a in "$@"; do
  case "$a" in
    --stop-ollama) STOP_OLLAMA=1 ;;
    --rm-model)    RM_MODEL=1 ;;
    --all)         STOP_OLLAMA=1; RM_MODEL=1 ;;
    *) warn "unknown flag: $a" ;;
  esac
done

CLUSTER="${KIND_CLUSTER_NAME:-kagent-n8n}"
COMPOSE_FILE="$REPO_ROOT/n8n/docker-compose.yaml"

# --- n8n compose stack ----------------------------------------------------
if [ -f "$COMPOSE_FILE" ]; then
  if docker compose -f "$COMPOSE_FILE" ps >/dev/null 2>&1; then
    log "stopping n8n Docker Compose stack..."
    docker compose -f "$COMPOSE_FILE" down -v || warn "compose down reported an issue"
    ok "n8n stack removed"
  fi
else
  log "no n8n compose file yet — skipping"
fi

# --- Kind cluster ---------------------------------------------------------
if have_cmd kind; then
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    log "deleting Kind cluster '${CLUSTER}'..."
    kind delete cluster --name "$CLUSTER"
    ok "Kind cluster '${CLUSTER}' deleted"
  else
    log "Kind cluster '${CLUSTER}' not present — skipping"
  fi
else
  warn "kind not installed — skipping cluster teardown"
fi

# --- Ollama (opt-in) ------------------------------------------------------
if [ "$RM_MODEL" = 1 ] && have_cmd ollama; then
  model="${LLM_MODEL:-llama3.2:1b}"
  if ollama list 2>/dev/null | grep -q "${model%%:*}"; then
    log "removing model ${model}..."
    ollama rm "$model" || warn "could not remove model ${model}"
  fi
fi

if [ "$STOP_OLLAMA" = 1 ]; then
  pidfile="$REPO_ROOT/.ollama.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log "stopping ollama serve (pid $(cat "$pidfile"))..."
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
    ok "ollama stopped"
  else
    warn "no tracked ollama process to stop (started outside this repo?)"
  fi
fi

ok "teardown complete"
