#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 35-llm-config.sh — resolve & verify the LLM endpoint the kagent pods will use.
#
# The resolved endpoint is written to LLM_ENDPOINT in .env and later injected
# straight into the kagent ModelConfig (no CoreDNS patching).
#
#   LLM_PROVIDER=ollama       -> the demo model is pulled onto the LOCAL (WSL)
#                                Ollama, then the pod-reachable host endpoint is
#                                resolved and verified from inside a pod.
#   LLM_PROVIDER=openai|azure -> use LLM_ENDPOINT as-is; probe egress reachability.
#
# Why probe from a pod (not the node)? Pods resolve via CoreDNS, which does not
# know host.docker.internal. We resolve candidate HOST IPs and verify the chosen
# one actually works from inside a Pod before committing it.
#
# Docker Desktop + WSL2 note: the pod->host path goes through the Windows host
# loopback, which the WSL2 NAT-mode mirror forwards to WSL ONLY for IPv4 sockets.
# Stock Ollama binds dual-stack [::] (even with OLLAMA_HOST=0.0.0.0), which
# IPv4-only Kind pods cannot reach. 20-ollama-up.sh binds Ollama to IPv4
# (OLLAMA_HOST=127.0.0.1:PORT via a systemd drop-in). See docs/troubleshooting.md.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd kubectl
require_cmd docker

CLUSTER="${KIND_CLUSTER_NAME:-kagent-n8n}"
CTX="kind-${CLUSTER}"
K="kubectl --context ${CTX}"
PROBE_IMAGE="curlimages/curl:8.11.1"
PORT="${OLLAMA_PORT:-11434}"
PROVIDER="${LLM_PROVIDER:-ollama}"

# probe_pod URL [bearer] -> 0 if a Pod gets any HTTP response from URL.
# curl exit 22 = HTTP >=400 (still "reachable", e.g. 401 from a hosted API).
probe_pod() {
  local url="$1" bearer="${2:-}" pod="llm-probe-$$"
  local hdr=""
  [ -n "$bearer" ] && hdr="-H \"Authorization: Bearer ${bearer}\""
  $K delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  $K run "$pod" --restart=Never --image="$PROBE_IMAGE" --command -- \
    sh -c "code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 ${hdr} '${url}'); echo HTTP=\$code; case \$code in 000) exit 1;; *) exit 0;; esac" \
    >/dev/null 2>&1 || true
  $K wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=60s >/dev/null 2>&1
  local rc=$?
  local out; out="$($K logs "$pod" 2>/dev/null || true)"
  $K delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  log "  probe ${url} -> ${out:-<no response>}"
  [ "$rc" -eq 0 ]
}

# host_gateway_ipv4 -> the IPv4 host.docker.internal maps to from a container
# (Docker Desktop: the host VM gateway; Docker Engine: host-gateway).
host_gateway_ipv4() {
  docker run --rm --add-host host.docker.internal:host-gateway "$PROBE_IMAGE" \
    sh -c 'getent ahosts host.docker.internal | awk "{print \$1}" | grep -E "^[0-9]+\." | head -1' 2>/dev/null
}

# kind_gateway_ipv4 -> the Kind docker-network gateway (host on native Engine).
kind_gateway_ipv4() {
  docker network inspect kind -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null \
    | grep -E '^[0-9]+\.' | head -1
}

# ensure_model_on_local_ollama — make sure LLM_MODEL exists on the LOCAL Ollama
# (http://127.0.0.1:PORT). The pull is driven against localhost so the model is
# always stored in the WSL Ollama, never a remote/foreign one.
ensure_model_on_local_ollama() {
  local host="http://127.0.0.1:${PORT}" model="${LLM_MODEL:-qwen2.5:1.5b}"
  curl -fsS --max-time 5 "${host}/api/tags" >/dev/null 2>&1 \
    || die "no local Ollama answering on ${host}. Start it (systemd: 'systemctl start ollama', or 'make ollama')."
  if curl -s --max-time 10 "${host}/api/tags" | grep -q "\"model\":\"${model}\""; then
    ok "model '${model}' already present on local Ollama"
    return 0
  fi
  log "pulling model '${model}' onto local Ollama (${host}) — one-time..."
  curl -s --max-time 3600 -X POST "${host}/api/pull" -d "{\"model\":\"${model}\"}" >/dev/null \
    || die "failed to pull '${model}' onto local Ollama"
  curl -s --max-time 10 "${host}/api/tags" | grep -q "\"model\":\"${model}\"" \
    || die "model '${model}' still missing after pull"
  ok "model '${model}' pulled onto local Ollama"
}

resolve_ollama() {
  # 1. The demo model lives on the LOCAL WSL Ollama.
  ensure_model_on_local_ollama

  # 2. Resolve the pod-reachable host endpoint that routes to that Ollama.
  if [ -n "${LLM_ENDPOINT:-}" ]; then
    log "LLM_ENDPOINT preset to ${LLM_ENDPOINT} — verifying from a pod"
    if probe_pod "${LLM_ENDPOINT%/}/api/tags"; then
      ok "Ollama reachable from the cluster at ${LLM_ENDPOINT}"
      return 0
    fi
    warn "preset LLM_ENDPOINT ${LLM_ENDPOINT} is not reachable from pods — re-deriving"
  fi

  log "auto-deriving a pod-reachable Ollama endpoint..."
  local hg kg cand ip seen=""
  hg="$(host_gateway_ipv4 || true)"
  kg="$(kind_gateway_ipv4 || true)"
  log "  candidates: host-gateway=${hg:-none} kind-gateway=${kg:-none}"
  for ip in "$hg" "$kg"; do
    [ -z "$ip" ] && continue
    case " $seen " in *" $ip "*) continue;; esac
    seen="$seen $ip"
    cand="http://${ip}:${PORT}"
    if probe_pod "${cand}/api/tags"; then
      upsert_env LLM_ENDPOINT "$cand"
      ok "selected Ollama endpoint ${cand} (verified from a pod)"
      return 0
    fi
  done

  die "no pod-reachable endpoint maps to your WSL Ollama on port ${PORT}.
  On Docker Desktop + WSL2 the pod->host path goes through the Windows host, which
  the WSL2 NAT-mode mirror forwards to WSL ONLY for IPv4 sockets. Stock Ollama
  binds dual-stack [::] (shown by 'ss' as '*:${PORT}'), which IPv4-only Kind pods
  cannot reach.

  Fix (keeps the default port ${PORT}): bind Ollama to IPv4 via a systemd drop-in,
  then re-run 'make up' (this is what 'make ollama' applies automatically):
      sudo mkdir -p /etc/systemd/system/ollama.service.d && \\
      printf '[Service]\\nEnvironment=\"OLLAMA_HOST=127.0.0.1:${PORT}\"\\n' \\
        | sudo tee /etc/systemd/system/ollama.service.d/ipv4.conf && \\
      sudo systemctl daemon-reload && sudo systemctl restart ollama

  Notes: OLLAMA_HOST=0.0.0.0 is NOT enough (Ollama still binds dual-stack); the
  Docker Desktop '*.docker.internal in /etc/hosts' and dual IPv4/IPv6 settings do
  NOT help. No-Ollama-change alternative: WSL mirrored networking.
  See docs/troubleshooting.md."
}

resolve_hosted() {
  [ -n "${LLM_ENDPOINT:-}" ] || die "LLM_PROVIDER=${PROVIDER} requires LLM_ENDPOINT in .env"
  local base="${LLM_ENDPOINT%/}" url
  case "$PROVIDER" in
    openai)      url="${base}/models" ;;          # /v1/models when base ends in /v1
    azureOpenAI) url="${base}/openai/models?api-version=2024-10-21" ;;
    *)           url="$base" ;;
  esac
  log "verifying hosted endpoint egress: ${url}"
  if probe_pod "$url" "${LLM_API_KEY:-}"; then
    ok "hosted LLM endpoint reachable from the cluster: ${LLM_ENDPOINT}"
  else
    die "hosted LLM endpoint ${LLM_ENDPOINT} is not reachable from the cluster"
  fi
}

log "resolving LLM config for provider '${PROVIDER}'"
case "$PROVIDER" in
  ollama)             resolve_ollama; load_env ;;
  openai|azureOpenAI) resolve_hosted ;;
  *) die "unknown LLM_PROVIDER '${PROVIDER}' (expected ollama|openai|azureOpenAI)" ;;
esac

load_env
ok "llm-config complete: provider=${PROVIDER} model=${LLM_MODEL:-?} endpoint=${LLM_ENDPOINT:-?}"
