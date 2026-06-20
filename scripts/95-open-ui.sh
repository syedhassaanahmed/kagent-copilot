#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 95-open-ui.sh — open the n8n editor on the imported A2A demo workflow so a
# live audience can click "Execute Workflow" and watch the A2A node run.
# Optionally also opens the kagent UI. Portable across Linux/WSL2/macOS.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

N8N_PORT="${N8N_PORT:-5678}"
WORKFLOW_ID="${N8N_WORKFLOW_ID:-a2a-demo}"
EDITOR_URL="http://localhost:${N8N_PORT}/workflow/${WORKFLOW_ID}"

# open_url <url> — best-effort browser open for the current OS.
open_url() {
  local url="$1"
  case "$(detect_os)" in
    macos) open "$url" >/dev/null 2>&1 && return 0 ;;
    wsl2)
      # Prefer the Windows browser from inside WSL.
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

# Make sure n8n is actually serving before we point a browser at it.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${N8N_PORT}/" 2>/dev/null || echo 000)"
if [ "$code" != "200" ]; then
  warn "n8n editor not reachable on :${N8N_PORT} (HTTP ${code}). Run 'make n8n-up workflow' first."
fi

log "n8n editor (A2A demo workflow):"
printf '\n    %s\n\n' "$EDITOR_URL"
log "Log in with the demo owner account:"
printf '    email:    %s\n    password: %s\n\n' "${N8N_OWNER_EMAIL:-demo@example.com}" "${N8N_OWNER_PASSWORD:-DemoPassw0rd}"
log "In the editor, click 'Execute Workflow' and watch the A2A node turn green;"
log "the kagent agent's reply appears in the 'A2A Response' node output panel."

if open_url "$EDITOR_URL"; then
  ok "Opened the workflow in your browser."
else
  warn "Could not auto-open a browser — copy the URL above manually."
fi
