#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 97-logs.sh — tail the kagent controller and demo agent logs.
#
# Usage: 97-logs.sh [kagent|agent|tunnel]   (default: all, non-following snapshot)
#        97-logs.sh -f [target]             (-f follows; pick a single target)
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

CLUSTER="${KIND_CLUSTER_NAME:-kagent-copilot}"
CTX="kind-${CLUSTER}"
K="kubectl --context ${CTX}"
NS="$(kagent_namespace)"
AGENT="${AGENT_NAME:-a2a-demo-agent}"

FOLLOW=""
if [ "${1:-}" = "-f" ]; then FOLLOW="-f"; shift; fi
TARGET="${1:-all}"
TAIL="${TAIL:-100}"

show_kagent() {
  log "== kagent controller =="
  $K -n "$NS" logs ${FOLLOW} --tail="$TAIL" -l app.kubernetes.io/component=controller 2>/dev/null || warn "controller logs unavailable"
}
show_agent() {
  log "== agent ${AGENT} =="
  $K -n "$NS" logs ${FOLLOW} --tail="$TAIL" -l "kagent.dev/agent=${AGENT}" 2>/dev/null \
    || $K -n "$NS" logs ${FOLLOW} --tail="$TAIL" "deploy/${AGENT}" 2>/dev/null \
    || warn "agent logs unavailable"
}
show_tunnel() {
  log "== devtunnel host =="
  local logf="$REPO_ROOT/.run/devtunnel-host.log"
  if [ -f "$logf" ]; then
    if [ -n "$FOLLOW" ]; then
      tail -n "$TAIL" -f "$logf"
    else
      tail -n "$TAIL" "$logf"
    fi
  else
    warn "no devtunnel host log at ${logf} — run 25-devtunnel-up.sh first"
  fi
}
case "$TARGET" in
  kagent) show_kagent ;;
  agent)  show_agent ;;
  tunnel) show_tunnel ;;
  all)
    [ -n "$FOLLOW" ] && die "use a single target with -f (kagent|agent|tunnel)"
    show_kagent; show_agent; show_tunnel ;;
  *) die "unknown target '${TARGET}' (kagent|agent|tunnel|all)" ;;
esac
