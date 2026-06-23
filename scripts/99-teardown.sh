#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 99-teardown.sh — tear the demo down. Idempotent: missing pieces are skipped.
#
# Removes (in reverse order of creation):
#   - local devtunnel host process, if this repo started one
#   - Kind cluster (which removes kagent + all CRs)
# Optionally removes cloud-side Copilot Studio / Dev Tunnel resources and stops
# Ollama / removes the model when called with flags.
#
# Usage:
#   99-teardown.sh                 # stop local tunnel host + UI forward; remove Kind cluster
#   99-teardown.sh --stop-ollama   # also stop the ollama serve we started
#   99-teardown.sh --rm-model      # also remove the pulled model
#   99-teardown.sh --copilot       # also delete Copilot Studio solution/fallback parts
#   99-teardown.sh --delete-tunnel # also delete the persistent named Dev Tunnel
#   99-teardown.sh --all           # stop-ollama + rm-model + copilot + delete-tunnel
#   99-teardown.sh --help          # print this usage
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_env

STOP_OLLAMA=0
RM_MODEL=0
DELETE_COPILOT=0
DELETE_TUNNEL=0
SHOW_HELP=0
for a in "$@"; do
  case "$a" in
    --stop-ollama) STOP_OLLAMA=1 ;;
    --rm-model)    RM_MODEL=1 ;;
    --copilot)     DELETE_COPILOT=1 ;;
    --delete-tunnel) DELETE_TUNNEL=1 ;;
    --all)         STOP_OLLAMA=1; RM_MODEL=1; DELETE_COPILOT=1; DELETE_TUNNEL=1 ;;
    --help|-h)
      SHOW_HELP=1
      ;;
    *) warn "unknown flag: $a" ;;
  esac
done

if [ "$SHOW_HELP" = 1 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

CLUSTER="${KIND_CLUSTER_NAME:-kagent-copilot}"
TUNNEL_NAME="${TUNNEL_NAME:-kagent-copilot-a2a}"
PAC_ENVIRONMENT_URL="${PAC_ENVIRONMENT_URL:-}"
COPILOT_AGENT_DISPLAY_NAME="${COPILOT_AGENT_DISPLAY_NAME:-kagent A2A Host}"
COPILOT_AGENT_SCHEMA_NAME="${COPILOT_AGENT_SCHEMA_NAME:-kagent_a2a_host}"
COPILOT_SOLUTION_NAME="${COPILOT_SOLUTION_NAME:-kagentcopilota2a}"
CONNECTOR_DISPLAY_NAME="${COPILOT_CONNECTOR_DISPLAY_NAME:-kagent A2A Demo Agent}"
COPILOT_CONNECTOR_API_NAME="${COPILOT_CONNECTOR_API_NAME:-}"

print_connection_manual_hint() {
  warn "manual fallback: Maker portal → Connections → delete the '${CONNECTOR_DISPLAY_NAME}' connection"
}

print_connector_manual_hint() {
  warn "manual fallback: Maker portal → Custom connectors → delete '${CONNECTOR_DISPLAY_NAME}'"
}

stop_devtunnel_host() {
  local pidfile pid
  pidfile="$REPO_ROOT/.run/devtunnel-host.pid"
  if [ ! -f "$pidfile" ]; then
    log "no tracked devtunnel host pidfile — skipping local host stop"
    return 0
  fi

  pid="$(tr -d '[:space:]' < "$pidfile" || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    log "stopping devtunnel host '${TUNNEL_NAME}' (pid ${pid})..."
    kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
    ok "devtunnel host stopped"
  else
    warn "stale or invalid devtunnel host pidfile — removing"
    rm -f "$pidfile"
  fi
}

delete_devtunnel() {
  if have_cmd devtunnel; then
    log "deleting persistent devtunnel '${TUNNEL_NAME}'..."
    devtunnel delete "$TUNNEL_NAME" --force || warn "could not delete devtunnel '${TUNNEL_NAME}'"
  else
    warn "devtunnel not installed — skipping persistent tunnel delete"
  fi
}

pac_env_args=()
if [ -n "$PAC_ENVIRONMENT_URL" ]; then
  pac_env_args=(--environment "$PAC_ENVIRONMENT_URL")
fi

delete_powerapps_connection() {
  if ! have_cmd python3; then
    warn "python3 not installed — cannot call PowerApps API for connection cleanup"
    print_connection_manual_hint
    return 0
  fi

  # pac connection delete is broken in default environments, so copilot_teardown.py
  # removes the environment-level connection via the PowerApps API instead.
  if ! PAC_ENVIRONMENT_URL="$PAC_ENVIRONMENT_URL" \
       CONNECTOR_DISPLAY_NAME="$CONNECTOR_DISPLAY_NAME" \
       COPILOT_CONNECTOR_API_NAME="$COPILOT_CONNECTOR_API_NAME" \
       python3 "$(dirname "$0")/copilot_teardown.py" connection
  then
    warn "PowerApps API connection cleanup failed"
    print_connection_manual_hint
  fi
}

find_connector_id() {
  [ -n "$PAC_ENVIRONMENT_URL" ] || return 0
  pac connector list --environment "$PAC_ENVIRONMENT_URL" 2>/dev/null \
    | awk -v display="$CONNECTOR_DISPLAY_NAME" 'index($0, display) > 0 { print $1; exit }' || true
}

delete_dataverse_connector() {
  local connector_id
  connector_id="$(find_connector_id || true)"
  if [ -z "$connector_id" ]; then
    log "no fallback connector id found for '${CONNECTOR_DISPLAY_NAME}' — skipping Dataverse connector delete"
    return 0
  fi
  if [ -z "$PAC_ENVIRONMENT_URL" ]; then
    warn "PAC_ENVIRONMENT_URL not set — cannot call Dataverse Web API for connector cleanup"
    print_connector_manual_hint
    return 0
  fi
  if ! have_cmd python3; then
    warn "python3 not installed — cannot call Dataverse Web API for connector cleanup"
    print_connector_manual_hint
    return 0
  fi

  # pac connector has no delete command in pac 2.8.1; copilot_teardown.py deletes
  # via the Dataverse Web API only if solution deletion did not remove it.
  if ! PAC_ENVIRONMENT_URL="$PAC_ENVIRONMENT_URL" \
       python3 "$(dirname "$0")/copilot_teardown.py" connector "$connector_id"
  then
    warn "Dataverse Web API connector cleanup failed"
    print_connector_manual_hint
  fi
}

delete_copilot_studio() {
  if ! have_cmd pac; then
    warn "pac not installed — skipping Copilot Studio teardown"
    print_connection_manual_hint
    print_connector_manual_hint
    return 0
  fi

  log "deleting Copilot Studio solution '${COPILOT_SOLUTION_NAME}'..."
  pac solution delete "${pac_env_args[@]}" --solution-name "$COPILOT_SOLUTION_NAME" \
    || warn "solution delete failed or solution was already absent: ${COPILOT_SOLUTION_NAME}"

  delete_powerapps_connection

  log "fallback deleting Copilot Studio agent '${COPILOT_AGENT_DISPLAY_NAME}' if still present..."
  # pac resolves --bot by Copilot ID or schema name, but the schema name is not
  # discoverable via `pac copilot list` and does not resolve reliably in pac
  # 2.8.1, so look up the deployed Copilot ID (GUID) by display name. If the
  # solution delete above already removed the agent, there is nothing to do.
  local copilot_id
  copilot_id="$( { pac copilot list "${pac_env_args[@]}" 2>/dev/null \
    | grep -F "$COPILOT_AGENT_DISPLAY_NAME" \
    | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1; } || true)"
  if [ -n "$copilot_id" ]; then
    pac copilot delete "${pac_env_args[@]}" --bot "$copilot_id" --confirm \
      || warn "copilot fallback delete failed: ${COPILOT_AGENT_DISPLAY_NAME} (${copilot_id})"
  else
    ok "copilot agent already absent: ${COPILOT_AGENT_DISPLAY_NAME}"
  fi
  delete_dataverse_connector
}

# --- local devtunnel host (best-effort; does not delete persistent tunnel) ---
stop_devtunnel_host

if [ "$DELETE_TUNNEL" = 1 ]; then
  delete_devtunnel
else
  log "persistent devtunnel '${TUNNEL_NAME}' retained — pass --delete-tunnel or --all to delete it"
fi

# --- stray kagent UI port-forward (best-effort) ---------------------------
# `make demo` may leave a background `kubectl port-forward svc/kagent-ui`.
# It would exit on its own once the cluster is gone, but clean it up proactively.
if have_cmd pkill; then
  if pkill -f 'port-forward.*svc/kagent-ui' 2>/dev/null; then
    ok "stopped kagent UI port-forward"
  fi
fi

# --- Kind cluster ---------------------------------------------------------
if have_cmd kind; then
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    log "deleting Kind cluster '${CLUSTER}'..."
    if kind delete cluster --name "$CLUSTER"; then
      ok "Kind cluster '${CLUSTER}' deleted"
    else
      warn "could not delete Kind cluster '${CLUSTER}'"
    fi
  else
    log "Kind cluster '${CLUSTER}' not present — skipping"
  fi
else
  warn "kind not installed — skipping cluster teardown"
fi

# --- Ollama (opt-in) ------------------------------------------------------
if [ "$RM_MODEL" = 1 ] && have_cmd ollama; then
  model="${LLM_MODEL:-qwen2.5:1.5b}"
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

# --- Copilot Studio / Power Platform (opt-in) ------------------------------
if [ "$DELETE_COPILOT" = 1 ]; then
  delete_copilot_studio
fi

ok "teardown complete"
