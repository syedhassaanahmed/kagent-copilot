#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 70-import-workflow.sh — import the n8n A2A demo workflow and credential.
#
# Idempotent:
#   - renders the A2A credential URL from .env on every run
#   - imports fixed workflow/credential IDs so re-runs update in place
#   - restarts n8n and waits for the editor to become healthy
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd docker
require_cmd curl

PORT="${N8N_PORT:-5678}"
A2A_NODE="${N8N_A2A_NODE:-@agentic-layer/n8n-nodes-a2a}"
KAGENT_PORT="${KAGENT_A2A_NODEPORT:-30883}"
KAGENT_NS="${AGENT_NAMESPACE:-kagent}"
KAGENT_AGENT="${AGENT_NAME:-a2a-demo-agent}"
COMPOSE_FILE="$REPO_ROOT/n8n/docker-compose.yaml"
WORKFLOW_FILE="$REPO_ROOT/n8n/workflows/a2a-demo.json"
CREDENTIALS_FILE="$REPO_ROOT/n8n/workflows/a2a-credentials.json"
CONTAINER_IMPORT_DIR="/home/node/.n8n/import"
CONTAINER_WORKFLOW_FILE="$CONTAINER_IMPORT_DIR/a2a-demo.json"
CONTAINER_CREDENTIALS_FILE="$CONTAINER_IMPORT_DIR/a2a-credentials.json"
SERVER_URL="http://host.docker.internal:${KAGENT_PORT}/api/a2a/${KAGENT_NS}/${KAGENT_AGENT}"

[ -f "$COMPOSE_FILE" ] || die "missing Compose file: ${COMPOSE_FILE}"
[ -f "$WORKFLOW_FILE" ] || die "missing workflow file: ${WORKFLOW_FILE}"
[ -f "$CREDENTIALS_FILE" ] || die "missing credentials file: ${CREDENTIALS_FILE}"

docker compose version >/dev/null 2>&1 || die "docker compose is required"

log "checking n8n container and installed community node..."
docker compose -f "$COMPOSE_FILE" ps n8n >/dev/null || die "n8n Compose service is not available"
docker compose -f "$COMPOSE_FILE" exec -T n8n sh -lc \
  "test -d '/home/node/.n8n/nodes/node_modules/${A2A_NODE}'" || die "community node '${A2A_NODE}' is not installed"
ok "community node '${A2A_NODE}' is installed"

log "verifying kagent A2A agent card from inside n8n container..."
docker compose -f "$COMPOSE_FILE" exec -T n8n node -e \
  "fetch('${SERVER_URL}/.well-known/agent-card.json').then(async (r) => { if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + await r.text()); console.log('agent card HTTP ' + r.status); }).catch((e) => { console.error(e.message || e); process.exit(1); })" >/dev/null
ok "A2A agent card reachable at ${SERVER_URL}/.well-known/agent-card.json"

log "copying workflow and rendered credential into the n8n container..."
docker compose -f "$COMPOSE_FILE" exec -T n8n sh -lc "mkdir -p '$CONTAINER_IMPORT_DIR'"
docker compose -f "$COMPOSE_FILE" cp "$WORKFLOW_FILE" "n8n:$CONTAINER_WORKFLOW_FILE" >/dev/null
escaped_server_url=$(printf '%s' "$SERVER_URL" | sed 's/[&#]/\\&/g')
sed "s#__A2A_SERVER_URL__#${escaped_server_url}#g" "$CREDENTIALS_FILE" | \
  docker compose -f "$COMPOSE_FILE" exec -T n8n sh -lc "cat > '$CONTAINER_CREDENTIALS_FILE'"
ok "prepared import files"

log "importing A2A credential and workflow..."
docker compose -f "$COMPOSE_FILE" exec -T n8n n8n import:credentials --input="$CONTAINER_CREDENTIALS_FILE"
docker compose -f "$COMPOSE_FILE" exec -T n8n n8n import:workflow --input="$CONTAINER_WORKFLOW_FILE"
ok "imported workflow id 'a2a-demo' with credential id 'a2a-demo-cred'"

log "restarting n8n so the editor reflects imported data..."
docker compose -f "$COMPOSE_FILE" restart n8n >/dev/null
wait_for "n8n HTTP on localhost:${PORT}" 180 bash -c \
  "curl -fsS --max-time 5 http://localhost:${PORT}/healthz >/dev/null || curl -fsS --max-time 5 http://localhost:${PORT}/rest/login >/dev/null || curl -fsS --max-time 5 http://localhost:${PORT}/ >/dev/null"

ok "n8n A2A demo workflow: http://localhost:${PORT}/workflow/a2a-demo"
