#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 90-demo-run.sh — headless replay of the n8n -> kagent A2A demo.
#
# Triggers the imported "A2A Demo" workflow inside the n8n container with
# n8n's CLI executor, then pretty-prints the kagent agent's A2A reply.
# Proves n8n <-> kagent communication end-to-end with no browser needed.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd docker
PORT="${N8N_PORT:-5678}"
WORKFLOW_ID="${N8N_WORKFLOW_ID:-a2a-demo}"
COMPOSE_FILE="$REPO_ROOT/n8n/docker-compose.yaml"

[ -f "$COMPOSE_FILE" ] || die "missing Compose file: ${COMPOSE_FILE}"
docker compose version >/dev/null 2>&1 || die "docker compose is required"

log "triggering n8n workflow '${WORKFLOW_ID}' headlessly..."
raw="$(docker compose -f "$COMPOSE_FILE" run --rm --no-deps n8n \
        execute --id "$WORKFLOW_ID" --rawOutput 2>/dev/null)" \
  || die "n8n execute failed — is the workflow imported? run 'make workflow'"

# n8n prints startup logs before the JSON run-data; keep from the first '{'.
json="${raw#"${raw%%\{*}"}"
[ -n "$json" ] || die "no JSON in n8n output (workflow may not have run)"

A2A_JSON="$json" python3 <<'PY'
import json, os, sys

# n8n may print trailing log lines (e.g. deprecation notices) AFTER the JSON
# run-data, so decode just the first JSON value and ignore any trailing output.
data, _ = json.JSONDecoder().raw_decode(os.environ["A2A_JSON"])

reply, status = None, None
def walk(o):
    global reply, status
    if isinstance(o, dict):
        if "agentReply" in o and reply is None:
            reply = o.get("agentReply")
        if "a2aStatus" in o and status is None:
            status = o.get("a2aStatus")
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)

walk(data)

if not reply:
    print("ERROR: no agent reply found in workflow output", file=sys.stderr)
    sys.exit(2)

bar = "=" * 68
print()
print(bar)
print("  n8n  ->  kagent   (A2A / Agent-to-Agent protocol)")
print(bar)
print(f"  A2A task status : {status or 'unknown'}")
print( "  Agent reply     :")
print(f"      {reply}")
print(bar)
print()
PY

ok "A2A round-trip complete — n8n received the kagent agent's reply."
