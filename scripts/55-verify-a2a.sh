#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 55-verify-a2a.sh — runtime smoke test of the live kagent A2A endpoint.
#
# Confirms, for each base URL checked:
#   1. the agent card is served at {agentURL}/.well-known/agent-card.json
#   2. a JSON-RPC `message/send` (legacy v0 — no version header) returns a
#      text answer from the agent (in task artifacts or message history).
#
# It always checks the LOCAL NodePort (http://localhost:<nodeport>/...). When
# TUNNEL_URL is set it ALSO checks the PUBLIC Dev Tunnel URL — the exact path
# Microsoft Copilot Studio uses — so a pass proves the cloud-reachable endpoint
# is healthy end to end. A2A traffic (JSON GET/POST) bypasses the Dev Tunnel
# anti-phishing interstitial; we still send X-Tunnel-Skip-AntiPhishing-Page as a
# belt-and-braces safety net for the tunnel pass.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd curl
require_cmd python3

NS="$(kagent_namespace)"
AGENT="${AGENT_NAME:-a2a-demo-agent}"
NODEPORT="$(a2a_nodeport)"
PROMPT="${1:-In one friendly sentence, introduce yourself and name the protocol we are communicating over.}"

# verify_base <label> <agent-base-url> [extra curl header]
# Returns 0 on a clean agent-card + message/send round-trip, non-zero otherwise.
verify_base() {
  local label="$1" base="$2" hdr="${3:-}"
  local card="${base}/.well-known/agent-card.json"
  local -a hargs=()
  [ -n "$hdr" ] && hargs=(-H "$hdr")

  # --- 1. agent card ------------------------------------------------------
  # Retry to ride out transient Dev Tunnel relay reconnects (the public host
  # periodically drops/reconnects its WebSocket; a request landing in that window
  # fails to connect and curl reports 000). Definitive HTTP errors are not retried.
  log "[${label}] GET ${card}"
  local tmp="/tmp/a2a-card.$$.${label}" code attempt
  for attempt in 1 2 3 4 5 6; do
    code="$(curl -s -o "$tmp" -w '%{http_code}' --max-time 15 "${hargs[@]}" "$card")" || code="000"
    case "$code" in
      200) break ;;
      000|502|503|504)
        [ "$attempt" -lt 6 ] && { log "[${label}] agent card not ready (HTTP ${code}) attempt ${attempt}/6 — retrying in 3s..."; sleep 3; } ;;
      *) break ;;  # definitive error (e.g. 404/401) — stop retrying
    esac
  done
  if [ "$code" != "200" ]; then
    cat "$tmp" 2>/dev/null; rm -f "$tmp"
    warn "[${label}] agent card not served (HTTP ${code})"
    return 1
  fi
  if ! python3 - "$tmp" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
print(f"[card] name={c.get('name')} skills={[s.get('id') for s in c.get('skills',[])]}")
PY
  then
    rm -f "$tmp"; warn "[${label}] agent card is not valid JSON"; return 1
  fi
  rm -f "$tmp"
  ok "[${label}] agent card served"

  # --- 2. message/send round-trip ----------------------------------------
  local mid="verify-$(date +%s)-$$" req resp
  read -r -d '' req <<EOF || true
{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"kind":"message","role":"user","messageId":"${mid}","parts":[{"kind":"text","text":"${PROMPT}"}]}}}
EOF

  log "[${label}] POST message/send -> ${base}/"
  local post_attempt
  resp=""
  for post_attempt in 1 2 3; do
    if resp="$(curl -sL --max-time 180 -X POST -H 'Content-Type: application/json' "${hargs[@]}" -d "$req" "${base}/")" && [ -n "$resp" ]; then
      break
    fi
    [ "$post_attempt" -lt 3 ] && { log "[${label}] message/send got no response (attempt ${post_attempt}/3) — retrying in 3s..."; sleep 3; }
  done
  if [ -z "$resp" ]; then
    warn "[${label}] message/send request failed (no response after retries)"; return 1
  fi

  RESP="$resp" python3 <<'PY'
import os,sys,json
raw=os.environ.get("RESP","")
if not raw.strip():
    print("[error] empty response from A2A endpoint"); sys.exit(2)
try:
    d=json.loads(raw)
except Exception as e:
    print("[error] non-JSON response:", str(e)); print(raw[:400]); sys.exit(2)
if "error" in d:
    print("[error]", d["error"]); sys.exit(1)
r=d.get("result",{}) or {}
state=(r.get("status") or {}).get("state")
answer=None
# kagent returns the reply as task artifacts (0.9.x A2A v0.3 message result)...
for a in r.get("artifacts",[]) or []:
    for p in a.get("parts",[]) or []:
        if p.get("kind")=="text" and p.get("text"): answer=p["text"]
# ...or as an agent message in history...
if not answer:
    for m in r.get("history",[]) or []:
        if m.get("role")=="agent":
            for p in m.get("parts",[]) or []:
                if p.get("kind")=="text": answer=p.get("text")
# ...or the result may itself be a Message object.
if not answer and r.get("kind")=="message" and r.get("role")=="agent":
    for p in r.get("parts",[]) or []:
        if p.get("kind")=="text": answer=p.get("text")
print(f"[state] {state}")
print(f"[agent] {answer}")
# Success = we got a non-empty answer and the task did not fail.
if not answer or state=="failed":
    sys.exit(2)
PY
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "[${label}] A2A round-trip did not complete successfully (see output above)"
    return 1
  fi
  ok "[${label}] message/send round-trip completed"
  return 0
}

# --- local pass (always) --------------------------------------------------
LOCAL_BASE="http://localhost:${NODEPORT}/api/a2a/${NS}/${AGENT}"
verify_base "local" "$LOCAL_BASE" \
  || die "local kagent A2A endpoint failed verification"
ok "local kagent A2A server is working"

# --- tunnel pass (the path Copilot Studio uses) ---------------------------
if [ -n "${TUNNEL_URL:-}" ]; then
  TUNNEL_BASE="${TUNNEL_URL%/}/api/a2a/${NS}/${AGENT}"
  if verify_base "tunnel" "$TUNNEL_BASE" "X-Tunnel-Skip-AntiPhishing-Page: true"; then
    ok "public Dev Tunnel A2A endpoint is working — Copilot Studio can reach kagent"
  else
    die "kagent is healthy locally but UNREACHABLE through the Dev Tunnel (${TUNNEL_BASE}) — check 25-devtunnel-up.sh / the host process"
  fi
else
  warn "TUNNEL_URL not set — skipped the public tunnel check (run 25-devtunnel-up.sh to verify the Copilot Studio path)"
fi

ok "verify-a2a passed"
