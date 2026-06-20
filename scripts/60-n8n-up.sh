#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 60-n8n-up.sh — run n8n with the community A2A node installed.
#
# Idempotent:
#   - reuses/updates the Docker Compose service
#   - installs the configured community node only when missing from the
#     persisted n8n user folder
#   - restarts n8n only after a first-time node install
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd docker
require_cmd curl

PORT="${N8N_PORT:-5678}"
A2A_NODE="${N8N_A2A_NODE:-@agentic-layer/n8n-nodes-a2a}"
COMPOSE_FILE="$REPO_ROOT/n8n/docker-compose.yaml"
NODES_DIR="/home/node/.n8n/nodes"
NODE_PACKAGE_DIR="${NODES_DIR}/node_modules/${A2A_NODE}"

[ -f "$COMPOSE_FILE" ] || die "missing Compose file: ${COMPOSE_FILE}"

docker compose version >/dev/null 2>&1 || die "docker compose is required"

log "starting n8n with Docker Compose..."
docker compose -f "$COMPOSE_FILE" up -d
ok "n8n Compose service is running"

if docker compose -f "$COMPOSE_FILE" exec -T n8n sh -lc "test -d '$NODE_PACKAGE_DIR'"; then
  ok "community node '${A2A_NODE}' already installed"
  installed_now=0
else
  log "installing community node '${A2A_NODE}' into ${NODES_DIR}..."
  docker compose -f "$COMPOSE_FILE" exec -T n8n sh -lc \
    "mkdir -p '$NODES_DIR' && cd '$NODES_DIR' && npm install '$A2A_NODE'"
  ok "community node '${A2A_NODE}' installed"
  installed_now=1
fi

if [ "$installed_now" -eq 1 ]; then
  log "restarting n8n so community nodes are loaded..."
  docker compose -f "$COMPOSE_FILE" restart n8n >/dev/null
fi

wait_for "n8n HTTP on localhost:${PORT}" 180 bash -c \
  "curl -fsS --max-time 5 http://localhost:${PORT}/healthz >/dev/null || curl -fsS --max-time 5 http://localhost:${PORT}/rest/login >/dev/null || curl -fsS --max-time 5 http://localhost:${PORT}/ >/dev/null"

if docker compose -f "$COMPOSE_FILE" exec -T n8n sh -lc "test -d '$NODE_PACKAGE_DIR'"; then
  ok "confirmed '${A2A_NODE}' under ${NODE_PACKAGE_DIR}"
else
  warn "could not confirm '${A2A_NODE}' under ${NODE_PACKAGE_DIR}; check n8n community nodes UI/logs"
fi

ok "n8n editor: http://localhost:${PORT}"
