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

# retry <attempts> <delay-seconds> <cmd...> — run cmd until it succeeds. The Dev
# Tunnels service is intermittently inconsistent and returns "Tunnel service
# error: Not Found" for tunnels that demonstrably exist, so most operations need
# a few attempts. Returns cmd's last exit status.
retry() {
  local attempts="$1" delay="$2"; shift 2
  local i
  for i in $(seq 1 "$attempts"); do
    if "$@"; then return 0; fi
    [ "$i" -lt "$attempts" ] && sleep "$delay"
  done
  return 1
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
  # The Dev Tunnels service is eventually consistent: operations issued right
  # after 'devtunnel create' can briefly fail with "Tunnel service error: Not
  # Found" until the new tunnel propagates. Wait until it is queryable.
  wait_for "devtunnel '${TUNNEL_NAME}' visible" 30 devtunnel show "$TUNNEL_NAME"
fi

# --- ensure A2A port exists -------------------------------------------------
# Retry port creation to ride out the same propagation delay (and re-check the
# port list each attempt so a partially-applied create is treated as success).
ensure_port() {
  local attempt
  for attempt in $(seq 1 6); do
    if devtunnel port list "$TUNNEL_NAME" 2>/dev/null \
         | grep -Eq "(^|[^0-9])${NODEPORT}([^0-9]|$)"; then
      return 0
    fi
    if devtunnel port create "$TUNNEL_NAME" -p "$NODEPORT" --protocol http; then
      return 0
    fi
    log "devtunnel not ready for port ${NODEPORT} (attempt ${attempt}/6) — retrying in 3s..."
    sleep 3
  done
  return 1
}

if ensure_port; then
  ok "devtunnel port ${NODEPORT} ensured"
else
  die "could not create devtunnel port ${NODEPORT}; the tunnel service may be slow — re-run 'make devtunnel' or inspect 'devtunnel show ${TUNNEL_NAME}'"
fi

# --- ensure anonymous access ------------------------------------------------
if [ "$is_anonymous" = true ]; then
  if retry 5 3 devtunnel access create "$TUNNEL_NAME" --anonymous; then
    ok "anonymous devtunnel access ensured"
  else
    warn "could not ensure anonymous devtunnel access after retries; set it manually if A2A clients get 401"
  fi
else
  warn "anonymous devtunnel access disabled by TUNNEL_ALLOW_ANONYMOUS=${TUNNEL_ALLOW_ANONYMOUS}"
fi

# --- host tunnel in background ---------------------------------------------
# A single 'devtunnel host' attempt can die on the service's transient "Not
# Found" before it connects — and before it logs the public URL (which uses an
# auto-generated id and can ONLY be read from this output). Retry the host until
# it reports readiness, truncating the log each attempt so readiness detection
# only ever sees the current run.
mkdir -p "$RUNDIR"

host_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

host_log_ready() {
  grep -Eq 'Ready to accept connections|Connect via browser|Hosting port' "$LOGFILE" 2>/dev/null
}

start_host_with_retry() {
  local attempt pid s
  for attempt in $(seq 1 8); do
    : > "$LOGFILE"
    nohup devtunnel host "$TUNNEL_NAME" >"$LOGFILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PIDFILE"
    for s in $(seq 1 20); do
      if host_log_ready; then
        ok "devtunnel host ready (pid ${pid}, log ${LOGFILE})"
        return 0
      fi
      kill -0 "$pid" 2>/dev/null || break   # host exited early (transient error)
      sleep 1
    done
    kill "$pid" 2>/dev/null || true
    log "devtunnel host not ready (attempt ${attempt}/8) — service flaky, retrying in 3s..."
    sleep 3
  done
  return 1
}

if host_running; then
  ok "devtunnel host already running (pid $(cat "$PIDFILE")) — skipping start"
elif start_host_with_retry; then
  :
else
  warn "devtunnel host did not become ready after retries; check ${LOGFILE}"
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
