#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 98-status.sh — one-glance status of every moving part of the demo.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

CLUSTER="${KIND_CLUSTER_NAME:-kagent-copilot}"
CTX="kind-${CLUSTER}"
K="kubectl --context ${CTX}"
NS="${KAGENT_NAMESPACE:-kagent}"
AGENT="${AGENT_NAME:-a2a-demo-agent}"
NODEPORT="${KAGENT_A2A_NODEPORT:-30883}"

hr() { printf '%s\n' "----------------------------------------------------------------"; }

hr; log "Host"
printf '  OS/arch     : %s/%s\n' "$(detect_os)" "$(detect_arch)"
printf '  LLM         : provider=%s model=%s endpoint=%s\n' \
  "${LLM_PROVIDER:-?}" "${LLM_MODEL:-?}" "${LLM_ENDPOINT:-?}"

hr; log "Ollama (${LLM_PROVIDER:-?})"
if [ "${LLM_PROVIDER:-ollama}" = ollama ]; then
  if curl -fsS --max-time 3 "http://127.0.0.1:${OLLAMA_PORT:-11434}/api/tags" >/dev/null 2>&1; then
    printf '  host server : up on :%s\n' "${OLLAMA_PORT:-11434}"
  else
    printf '  host server : DOWN\n'
  fi
else
  printf '  hosted provider — no local Ollama\n'
fi

hr; log "Kind cluster '${CLUSTER}'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  $K get nodes 2>/dev/null | sed 's/^/  /' || true
else
  printf '  not present\n'
fi

hr; log "kagent (namespace ${NS})"
if $K get ns "$NS" >/dev/null 2>&1; then
  $K -n "$NS" get agent "$AGENT" 2>/dev/null | sed 's/^/  /' || printf '  agent %s not found\n' "$AGENT"
  $K -n "$NS" get modelconfig a2a-demo-modelconfig 2>/dev/null | sed 's/^/  /' || true
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${NODEPORT}/api/a2a/${NS}/${AGENT}/.well-known/agent-card.json" 2>/dev/null || echo 000)"
  printf '  A2A card    : http://localhost:%s/api/a2a/%s/%s/.well-known/agent-card.json (HTTP %s)\n' "$NODEPORT" "$NS" "$AGENT" "$code"
else
  printf '  not installed\n'
fi

hr; log "Dev Tunnel (public A2A exposure)"
TUNNEL_NAME="${TUNNEL_NAME:-kagent-copilot-a2a}"
pidfile="$REPO_ROOT/.run/devtunnel-host.pid"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  printf '  host process: up (pid %s)\n' "$(cat "$pidfile")"
else
  printf '  host process: DOWN (run 25-devtunnel-up.sh / make devtunnel)\n'
fi
printf '  tunnel name : %s\n' "$TUNNEL_NAME"
if [ -n "${TUNNEL_URL:-}" ]; then
  printf '  TUNNEL_URL  : %s\n' "$TUNNEL_URL"
  tcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -H 'X-Tunnel-Skip-AntiPhishing-Page: true' \
    "${TUNNEL_URL%/}/api/a2a/${NS}/${AGENT}/.well-known/agent-card.json" 2>/dev/null || echo 000)"
  printf '  card (tunnel): %s/api/a2a/%s/%s/.well-known/agent-card.json (HTTP %s)\n' "${TUNNEL_URL%/}" "$NS" "$AGENT" "$tcode"
else
  printf '  TUNNEL_URL  : not set (run 25-devtunnel-up.sh)\n'
fi

hr; log "Power Platform / Copilot Studio"
printf '  env URL     : %s\n' "${PAC_ENVIRONMENT_URL:-<unset>}"
if have_cmd pac; then
  if pac auth list >/dev/null 2>&1 && pac auth list 2>/dev/null | grep -q '\*'; then
    printf '  pac auth    : active profile selected\n'
  else
    printf '  pac auth    : no active profile (run 60-copilot-deploy.sh / make copilot)\n'
  fi
else
  printf '  pac         : not installed (run make tools)\n'
fi
printf '  host agent  : %s (schema %s, solution %s)\n' \
  "${COPILOT_AGENT_DISPLAY_NAME:-kagent A2A Host}" "${COPILOT_AGENT_SCHEMA_NAME:-kagent_a2a_host}" "${COPILOT_SOLUTION_NAME:-kagentcopilota2a}"
printf '  A2A endpoint: %s\n' "${TUNNEL_URL:+${TUNNEL_URL%/}/api/a2a/${NS}/${AGENT}}"
hr
