#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 25-devtunnel-up.sh — expose the local kagent A2A endpoint over HTTPS.
#
# Ensures a stable Microsoft Dev Tunnel exists, forwards the configured kagent
# A2A NodePort, resolves the public HTTPS URL, writes TUNNEL_URL to .env, and
# starts devtunnel host in the background. Idempotent.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd devtunnel "Install Microsoft Dev Tunnels CLI: https://aka.ms/devtunnels"
require_cmd grep
require_cmd nohup

TUNNEL_NAME="${TUNNEL_NAME:-kagent-copilot-a2a}"
TUNNEL_ALLOW_ANONYMOUS="${TUNNEL_ALLOW_ANONYMOUS:-true}"
NODEPORT="${KAGENT_A2A_NODEPORT:-30883}"
RUNDIR="$REPO_ROOT/.run"
PIDFILE="$RUNDIR/devtunnel-host.pid"
LOGFILE="$RUNDIR/devtunnel-host.log"

resolve_tunnel_url() {
  devtunnel show "$TUNNEL_NAME" 2>/dev/null || true
  devtunnel port list "$TUNNEL_NAME" 2>/dev/null || true
  if [ -f "$LOGFILE" ]; then
    cat "$LOGFILE"
  fi
}

is_anonymous=false
case "${TUNNEL_ALLOW_ANONYMOUS,,}" in
  true|1|yes|y) is_anonymous=true ;;
esac

# --- ensure CLI login -------------------------------------------------------
if devtunnel user show >/dev/null 2>&1; then
  ok "devtunnel user already logged in"
else
  log "devtunnel login required..."
  if devtunnel user login; then
    ok "devtunnel login complete"
  else
    die "devtunnel login failed; run 'devtunnel user login' manually, then re-run this script"
  fi
fi

# --- ensure tunnel exists ---------------------------------------------------
if devtunnel show "$TUNNEL_NAME" >/dev/null 2>&1; then
  ok "devtunnel '${TUNNEL_NAME}' already exists — skipping create"
else
  log "creating devtunnel '${TUNNEL_NAME}'..."
  create_args=(create "$TUNNEL_NAME")
  if [ "$is_anonymous" = true ]; then
    create_args+=(--allow-anonymous)
  fi
  devtunnel "${create_args[@]}"
  ok "devtunnel '${TUNNEL_NAME}' created"
fi

# --- ensure A2A port exists -------------------------------------------------
if devtunnel port list "$TUNNEL_NAME" 2>/dev/null | grep -Eq "(^|[^0-9])${NODEPORT}([^0-9]|$)"; then
  ok "devtunnel port ${NODEPORT} already exists — skipping create"
else
  log "creating devtunnel port ${NODEPORT}..."
  devtunnel port create "$TUNNEL_NAME" -p "$NODEPORT" --protocol http
  ok "devtunnel port ${NODEPORT} created"
fi

# --- ensure anonymous access ------------------------------------------------
if [ "$is_anonymous" = true ]; then
  devtunnel access create "$TUNNEL_NAME" --anonymous || true
  ok "anonymous devtunnel access ensured"
else
  warn "anonymous devtunnel access disabled by TUNNEL_ALLOW_ANONYMOUS=${TUNNEL_ALLOW_ANONYMOUS}"
fi

# --- host tunnel in background ---------------------------------------------
mkdir -p "$RUNDIR"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  ok "devtunnel host already running (pid $(cat "$PIDFILE")) — skipping start"
else
  log "starting devtunnel host '${TUNNEL_NAME}'..."
  nohup devtunnel host "$TUNNEL_NAME" >"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  ok "devtunnel host started (pid $(cat "$PIDFILE"), log ${LOGFILE})"

  if ( wait_for "devtunnel host up" 30 bash -c "grep -Eq 'Connect via browser|Hosting port' '$LOGFILE'" ); then
    :
  else
    warn "devtunnel host did not report readiness within 30s; check ${LOGFILE}"
  fi
fi

# --- resolve public URL -----------------------------------------------------
url="$(
  resolve_tunnel_url \
    | grep -oE 'https://[a-z0-9.-]+\.devtunnels\.ms[^ ]*' \
    | grep -- "-${NODEPORT}\." \
    | head -n 1 \
    | sed 's#/$##' || true
)"

if [ -z "$url" ]; then
  die "could not resolve a https://...devtunnels.ms URL for port ${NODEPORT} from devtunnel output; check ${LOGFILE}"
fi

upsert_env TUNNEL_URL "$url"
export TUNNEL_URL="$url"

log "Tunnel name: ${TUNNEL_NAME}"
log "TUNNEL_URL: ${TUNNEL_URL}"
log "A2A endpoint (give this to Copilot Studio): ${TUNNEL_URL}/api/a2a/${AGENT_NAMESPACE:-kagent}/${AGENT_NAME:-a2a-demo-agent}"
log "Agent card: ${TUNNEL_URL}/api/a2a/${AGENT_NAMESPACE:-kagent}/${AGENT_NAME:-a2a-demo-agent}/.well-known/agent-card.json"
ok "devtunnel-up complete"
