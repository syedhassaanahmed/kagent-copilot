#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 95-open-ui.sh — expose + open the kagent UI via a background port-forward.
# Portable across Linux/WSL2/macOS.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

CLUSTER="${KIND_CLUSTER_NAME:-kagent-copilot}"
CTX="kind-${CLUSTER}"
KAGENT_NS="${KAGENT_NAMESPACE:-kagent}"
KAGENT_UI_PORT="${KAGENT_UI_PORT:-8080}"
KAGENT_UI_URL="http://localhost:${KAGENT_UI_PORT}"
NODEPORT="${KAGENT_A2A_NODEPORT:-30883}"
AGENT_NS="${AGENT_NAMESPACE:-kagent}"
AGENT="${AGENT_NAME:-a2a-demo-agent}"
A2A_URL="http://localhost:${NODEPORT}/api/a2a/${AGENT_NS}/${AGENT}"
COPILOT_STUDIO_URL="${COPILOT_STUDIO_URL:-https://copilotstudio.microsoft.com/}"
COPILOT_AGENT_DISPLAY_NAME="${COPILOT_AGENT_DISPLAY_NAME:-kagent A2A Host}"
PAC_ENVIRONMENT_URL="${PAC_ENVIRONMENT_URL:-$(pac_env_url 2>/dev/null || true)}"
PUBLIC_A2A_URL="${TUNNEL_URL:+${TUNNEL_URL%/}/api/a2a/${AGENT_NS}/${AGENT}}"
TEST_PROMPT="${TEST_PROMPT:-Ask the kagent agent to introduce itself and name the protocol you are talking over.}"

open_url() {
  local url="$1"
  case "$(detect_os)" in
    macos) open "$url" >/dev/null 2>&1 && return 0 ;;
    wsl2)
      if have_cmd wslview; then wslview "$url" >/dev/null 2>&1 && return 0; fi
      if have_cmd powershell.exe; then powershell.exe -NoProfile Start-Process "$url" >/dev/null 2>&1 && return 0; fi
      if have_cmd xdg-open; then xdg-open "$url" >/dev/null 2>&1 && return 0; fi
      ;;
    *)
      if have_cmd xdg-open; then xdg-open "$url" >/dev/null 2>&1 && return 0; fi
      ;;
  esac
  return 1
}

ui_reachable() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$KAGENT_UI_URL/" 2>/dev/null || echo 000)" = "200" ]
}

print_binding_steps() {
  warn "ONE-TIME MANUAL STEP — connect the A2A agent to the host agent (do this once in the maker portal)"
  printf '%s\n' \
    "  pac has no command to bind an A2A agent and the binding is not part of the" \
    "  deployed solution, so it must be added by hand. Until it is done the host agent" \
    "  answers from its own model and WILL NOT delegate to kagent." \
    "" \
    "  1. In Copilot Studio${PAC_ENVIRONMENT_URL:+ (environment '${PAC_ENVIRONMENT_URL}')}, open the host agent: ${COPILOT_AGENT_DISPLAY_NAME}" \
    "  2. Agents -> Add agent -> A2A agent" \
    "       Endpoint: ${PUBLIC_A2A_URL:-<run 'make devtunnel' first to get the public endpoint>}" \
    "       Auth:     None" \
    "       Save" \
    "  3. Publish the host agent (top-right Publish button) so the binding goes live" \
    "  4. Send this prompt in the host agent's Test pane:" \
    "       ${TEST_PROMPT}" \
    "" \
    "  This is a one-time action per agent; it survives subsequent re-deploys."
}

ensure_kagent_ui_forward() {
  if ui_reachable; then
    ok "kagent UI already reachable on :${KAGENT_UI_PORT}"
    return 0
  fi
  have_cmd kubectl || { warn "kubectl not found — skipping kagent UI (open it manually with port-forward)"; return 1; }
  kubectl --context "$CTX" -n "$KAGENT_NS" get svc kagent-ui >/dev/null 2>&1 || {
    warn "kagent UI service not found in context ${CTX} — is the cluster up? skipping"; return 1; }

  mkdir -p "$REPO_ROOT/.tmp"
  local logf="$REPO_ROOT/.tmp/kagent-ui-portforward.log"
  log "starting background port-forward for the kagent UI (svc/kagent-ui ${KAGENT_UI_PORT}:8080)..."
  setsid kubectl --context "$CTX" -n "$KAGENT_NS" \
    port-forward "svc/kagent-ui" "${KAGENT_UI_PORT}:8080" >"$logf" 2>&1 &
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ui_reachable && { ok "kagent UI reachable on :${KAGENT_UI_PORT}"; return 0; }
    sleep 1
  done
  warn "kagent UI port-forward did not become ready (see ${logf}); continuing without it"
  return 1
}

# --- resolve a deep link straight to the host agent, if we can -----------
# https://copilotstudio.microsoft.com/environments/{envId}/bots/{copilotId}/overview
# Needs the Power Platform environment id + the deployed Copilot (bot) GUID; both
# require an authenticated pac. Falls back to the generic portal otherwise. The
# connected-agent id can't be known here (it only exists after the manual bind).
resolve_copilot_studio_url() {
  local base="${COPILOT_STUDIO_URL%/}" env_id bot_id
  env_id="$(pac_env_id 2>/dev/null || true)"
  bot_id="$(copilot_id "$COPILOT_AGENT_DISPLAY_NAME" "$PAC_ENVIRONMENT_URL" 2>/dev/null || true)"
  if [ -n "$env_id" ] && [ -n "$bot_id" ]; then
    printf '%s/environments/%s/bots/%s/overview' "$base" "$env_id" "$bot_id"
  else
    printf '%s' "$COPILOT_STUDIO_URL"
  fi
}

log "Local kagent A2A endpoint:"
printf '\n    %s\n\n' "$A2A_URL"
if [ -n "${TUNNEL_URL:-}" ]; then
  log "Public A2A endpoint (give this to Copilot Studio):"
  printf '\n    %s\n\n' "${TUNNEL_URL%/}/api/a2a/${AGENT_NS}/${AGENT}"
else
  log "Expose that endpoint with Microsoft Dev Tunnels (make devtunnel) for Copilot Studio cloud access."
fi

# --- open the kagent UI ---------------------------------------------------
if ensure_kagent_ui_forward; then
  log "kagent UI:"
  printf '\n    %s\n\n' "$KAGENT_UI_URL"
  if open_url "$KAGENT_UI_URL"; then ok "Opened the kagent UI in your browser."
  else warn "Could not auto-open the kagent UI — copy ${KAGENT_UI_URL} manually."; fi
  log "(the kagent UI stays up via a background port-forward; it ends when you stop it or tear down the cluster)"
fi

# --- open the Copilot Studio maker portal --------------------------------
COPILOT_STUDIO_URL="$(resolve_copilot_studio_url)"
log "Copilot Studio (cloud A2A orchestrator):"
printf '\n    %s\n\n' "$COPILOT_STUDIO_URL"
if open_url "$COPILOT_STUDIO_URL"; then
  ok "Opened Microsoft Copilot Studio in your browser."
else
  warn "Could not auto-open Copilot Studio — visit ${COPILOT_STUDIO_URL} manually."
fi

print_binding_steps
log "Copilot Studio delegates to kagent over A2A through the tunnel; watch 'make logs tunnel' / 'make logs agent'."
