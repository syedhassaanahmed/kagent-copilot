#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 55-verify-a2a.sh — runtime smoke test of the live kagent A2A endpoint.
#
# Confirms (from the host, through the Kind-published NodePort):
#   1. the agent card is served at {agentURL}/.well-known/agent-card.json
#   2. a JSON-RPC `message/send` (legacy v0 — no version header) returns a
#      completed task with a text answer from the agent.
#
# This is exactly the shape the n8n A2A node uses, so a pass here means n8n
# will be able to talk to the agent.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd curl
require_cmd python3

NS="${AGENT_NAMESPACE:-kagent}"
AGENT="${AGENT_NAME:-a2a-demo-agent}"
NODEPORT="${KAGENT_A2A_NODEPORT:-30883}"

# Host-reachable agent base (same path n8n uses, but via localhost).
BASE="http://localhost:${NODEPORT}/api/a2a/${NS}/${AGENT}"
CARD="${BASE}/.well-known/agent-card.json"

# --- 1. agent card --------------------------------------------------------
log "GET ${CARD}"
code="$(curl -s -o /tmp/a2a-card.$$ -w '%{http_code}' --max-time 15 "$CARD" || echo 000)"
[ "$code" = "200" ] || { cat "/tmp/a2a-card.$$" 2>/dev/null; rm -f "/tmp/a2a-card.$$"; die "agent card not served (HTTP ${code})"; }
python3 - "/tmp/a2a-card.$$" <<'PY' || die "agent card is not valid JSON"
import json,sys
c=json.load(open(sys.argv[1]))
print(f"[card] name={c.get('name')} skills={[s.get('id') for s in c.get('skills',[])]}")
PY
rm -f "/tmp/a2a-card.$$"
ok "agent card served"

# --- 2. message/send round-trip ------------------------------------------
PROMPT="${1:-In one friendly sentence, introduce yourself and name the protocol we are communicating over.}"
MID="verify-$(date +%s)"
read -r -d '' REQ <<EOF || true
{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"kind":"message","role":"user","messageId":"${MID}","parts":[{"kind":"text","text":"${PROMPT}"}]}}}
EOF

log "POST message/send -> ${BASE}"
resp="$(curl -s --max-time 180 -X POST -H 'Content-Type: application/json' -d "$REQ" "$BASE")" \
  || die "message/send request failed"

RESP="$resp" python3 <<'PY'
import os,sys,json
raw=os.environ.get("RESP","")
if not raw.strip():
    print("[error] empty response from A2A endpoint"); sys.exit(2)
d=json.loads(raw)
if "error" in d:
    print("[error]", d["error"]); sys.exit(1)
r=d.get("result",{})
state=r.get("status",{}).get("state")
answer=None
for m in r.get("history",[]):
    if m.get("role")=="agent":
        for p in m.get("parts",[]):
            if p.get("kind")=="text": answer=p["text"]
print(f"[state] {state}")
print(f"[agent] {answer}")
if state!="completed" or not answer:
    sys.exit(2)
PY
rc=$?
[ "$rc" -eq 0 ] || die "A2A round-trip did not complete successfully (see output above)"
ok "verify-a2a passed — n8n <-> kagent A2A is working"
