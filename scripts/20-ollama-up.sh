#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 20-ollama-up.sh — ensure a host Ollama server reachable from Kind pods, with
# the demo model pulled. Runs only when LLM_PROVIDER=ollama; no-op otherwise.
#
# Idempotent:
#   - reuses an already-running server if one answers on $OLLAMA_PORT
#   - otherwise starts one bound to 127.0.0.1:$OLLAMA_PORT (pid in .ollama.pid)
#   - ensures an IPv4 listener (see below), pulling LLM_MODEL only if missing
#
# Why IPv4 (Docker Desktop + WSL2):
#   IPv4-only Kind pods reach the WSL host through the Windows loopback, which the
#   WSL2 NAT-mode mirror forwards ONLY for IPv4 sockets. Stock Ollama binds
#   dual-stack [::] (shown by `ss` as `*:11434`) even with OLLAMA_HOST=0.0.0.0,
#   which that mirror skips. Binding 127.0.0.1 yields a true IPv4 socket the mirror
#   forwards. For a systemd-managed Ollama this is applied via a drop-in setting
#   OLLAMA_HOST=127.0.0.1:$OLLAMA_PORT (sudo may prompt). A no-Ollama-change
#   alternative is WSL mirrored networking. See docs/troubleshooting.md.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

if [ "${LLM_PROVIDER:-ollama}" != "ollama" ]; then
  log "LLM_PROVIDER=${LLM_PROVIDER:-} — Ollama not needed, skipping"
  exit 0
fi

require_cmd ollama
PORT="${OLLAMA_PORT:-11434}"
MODEL="${LLM_MODEL:-qwen2.5:1.5b}"
PIDFILE="$REPO_ROOT/.ollama.pid"

api_up() { curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/tags" >/dev/null 2>&1; }

# has_ipv4_listener — true only for an explicit IPv4 listener (0.0.0.0 / 127.0.0.1)
# on $PORT. Dual-stack/IPv6 (* / [::]) does NOT count.
has_ipv4_listener() {
  if have_cmd ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|127\.0\.0\.1):${PORT}$"
  elif have_cmd lsof; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | grep -qE '(0\.0\.0\.0|127\.0\.0\.1):'"${PORT}"
  else
    return 0   # can't tell; assume ok
  fi
}

# run_sudo — run a privileged command, preferring non-interactive sudo, falling
# back to an interactive prompt when attached to a TTY (e.g. user runs `make up`).
run_sudo() {
  if sudo -n true 2>/dev/null; then
    sudo -n "$@"
  elif [ -t 0 ] || [ -t 1 ]; then
    sudo "$@"
  else
    return 1
  fi
}

systemd_ollama() { systemctl list-unit-files 2>/dev/null | grep -qE '^ollama\.service'; }

# apply_ipv4_dropin — set OLLAMA_HOST=127.0.0.1:$PORT on the systemd Ollama via a
# drop-in and restart it. The drop-in is named to sort LAST (systemd merges *.d
# files alphabetically, last assignment of a variable wins) so it overrides any
# pre-existing override.conf that sets OLLAMA_HOST=0.0.0.0. Returns 0 only if an
# IPv4 listener results.
apply_ipv4_dropin() {
  local dropdir=/etc/systemd/system/ollama.service.d
  ( sudo -n true 2>/dev/null || [ -t 0 ] || [ -t 1 ] ) || return 1
  log "applying systemd drop-in OLLAMA_HOST=127.0.0.1:${PORT} (sudo may prompt)..."
  run_sudo mkdir -p "$dropdir" || return 1
  run_sudo rm -f "$dropdir/ipv4.conf" 2>/dev/null || true   # remove stale early-sorting drop-in
  printf '[Service]\nEnvironment="OLLAMA_HOST=127.0.0.1:%s"\n' "$PORT" \
    | run_sudo tee "$dropdir/zz-ipv4.conf" >/dev/null || return 1
  run_sudo systemctl daemon-reload || return 1
  run_sudo systemctl restart ollama || return 1
  sleep 3
  has_ipv4_listener
}

instruct_ipv4_and_die() {
  local dropdir=/etc/systemd/system/ollama.service.d
  die "Ollama on :${PORT} is bound dual-stack/IPv6 ('*:${PORT}') — IPv4-only Kind
  pods cannot reach it through the WSL2 NAT-mode mirror.

  Apply the IPv4 bind once (keeps the default port ${PORT}), then re-run 'make up'.
  Note: the drop-in is named 'zz-ipv4.conf' so it overrides any existing
  override.conf (systemd merges *.d files alphabetically; last wins):

    sudo rm -f ${dropdir}/ipv4.conf; \\
    sudo mkdir -p ${dropdir} && \\
    printf '[Service]\\nEnvironment=\"OLLAMA_HOST=127.0.0.1:${PORT}\"\\n' \\
      | sudo tee ${dropdir}/zz-ipv4.conf && \\
    sudo systemctl daemon-reload && sudo systemctl restart ollama

  Verify with: ss -ltn | grep ${PORT}   (expect 127.0.0.1:${PORT}, not *:${PORT})
  (No-Ollama-change alternative: WSL mirrored networking — see docs/troubleshooting.md.)"
}

ensure_ipv4() {
  has_ipv4_listener && { ok "Ollama has an IPv4 listener on :${PORT} (pod-reachable)"; return 0; }
  warn "Ollama on :${PORT} is bound dual-stack/IPv6 — IPv4-only Kind pods cannot reach it."
  if systemd_ollama; then
    apply_ipv4_dropin && { ok "Ollama rebound to IPv4 127.0.0.1:${PORT}"; return 0; }
  fi
  instruct_ipv4_and_die
}

if api_up; then
  ok "reusing existing Ollama server on :${PORT}"
  ensure_ipv4
else
  log "starting 'ollama serve' on 127.0.0.1:${PORT} (IPv4)..."
  OLLAMA_HOST="127.0.0.1:${PORT}" nohup ollama serve >"$REPO_ROOT/.ollama.log" 2>&1 &
  echo $! > "$PIDFILE"
  wait_for "ollama API on :${PORT}" 60 bash -c "curl -fsS --max-time 3 http://127.0.0.1:${PORT}/api/tags >/dev/null"
  ensure_ipv4
fi

# --- model ----------------------------------------------------------------
if OLLAMA_HOST="127.0.0.1:${PORT}" ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  ok "model '${MODEL}' already present"
else
  log "pulling model '${MODEL}' (one-time)..."
  OLLAMA_HOST="127.0.0.1:${PORT}" ollama pull "$MODEL"
  ok "model '${MODEL}' pulled"
fi

# Confirm the model can be seen via the API the cluster will use.
if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/tags" | grep -q "\"${MODEL%%:*}"; then
  ok "Ollama ready: model '${MODEL}' served on :${PORT}"
else
  warn "model '${MODEL}' not visible via API yet — check 'ollama list'"
fi
