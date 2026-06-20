#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 35-llm-config.sh — resolve & verify the LLM endpoint the kagent pods will use.
#
# No CoreDNS patching. The resolved endpoint is written to LLM_ENDPOINT in .env
# and later injected straight into the kagent ModelConfig.
#
#   LLM_PROVIDER=ollama       -> if LLM_ENDPOINT unset, auto-derive a pod-
#                                reachable host endpoint (platform-aware) and
#                                probe it from an in-cluster pod.
#   LLM_PROVIDER=openai|azure -> use LLM_ENDPOINT as-is; probe egress reachability.
#
# Why probe from a pod (not the node)? Pods resolve via CoreDNS, which does not
# know host.docker.internal. We therefore resolve candidate HOST IPs and verify
# the chosen one actually works from inside a Pod before committing it.
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

# probe_pod URL [bearer] -> 0 if the URL returns any HTTP response from a Pod.
# Uses -f for connectivity but treats HTTP 4xx as "reachable" (e.g. 401 from a
# hosted API still proves egress works).
probe_pod() {
  local url="$1" bearer="${2:-}" pod="llm-probe-$$"
  local hdr=""
  [ -n "$bearer" ] && hdr="-H \"Authorization: Bearer ${bearer}\""
  $K delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  # curl exit 22 = HTTP >=400 (reachable); 0 = success. Both mean "connected".
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

# host_gateway_ipv4 -> the IPv4 that host.docker.internal maps to from a
# container (Docker Desktop: the host VM gateway; Docker Engine: host-gateway).
host_gateway_ipv4() {
  docker run --rm --add-host host.docker.internal:host-gateway "$PROBE_IMAGE" \
    sh -c 'getent ahosts host.docker.internal | awk "{print \$1}" | grep -E "^[0-9]+\." | head -1' 2>/dev/null
}

# kind_gateway_ipv4 -> the Kind docker-network gateway (host on native Engine).
kind_gateway_ipv4() {
  docker network inspect kind -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null \
    | grep -E '^[0-9]+\.' | head -1
}

resolve_ollama() {
  if [ -n "${LLM_ENDPOINT:-}" ]; then
    log "LLM_ENDPOINT preset to ${LLM_ENDPOINT} — verifying from a pod"
    probe_pod "${LLM_ENDPOINT%/}/api/tags" \
      && { ok "Ollama reachable at ${LLM_ENDPOINT}"; return 0; }
    die "preset LLM_ENDPOINT ${LLM_ENDPOINT} is not reachable from the cluster"
  fi

  log "auto-deriving a pod-reachable Ollama endpoint (platform-aware)..."
  local hg kg cand seen=""
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

  die "no candidate Ollama endpoint was reachable from the cluster.
  Ensure Ollama is running and bound to 0.0.0.0:${PORT} (OLLAMA_HOST=0.0.0.0:${PORT} ollama serve),
  or set LLM_ENDPOINT in .env to an address routable from Kind pods."
}

# ensure_ollama_model — make sure LLM_MODEL exists ON the resolved endpoint.
# On Docker Desktop the pod-reachable Ollama may differ from the host CLI's
# Ollama, so we drive the pull through the endpoint's REST API from inside the
# cluster (idempotent: skips if the model is already present there).
ensure_ollama_model() {
  local ep="${LLM_ENDPOINT%/}" model="${LLM_MODEL:-llama3.2:1b}" pod="ollama-model-$$"
  log "ensuring model '${model}' is present on ${ep} (pull via API if missing)..."
  $K delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  $K run "$pod" --restart=Never --image="$PROBE_IMAGE" --command -- sh -c "
    if curl -s --max-time 10 '${ep}/api/tags' | grep -q '\"model\":\"${model}\"'; then
      echo MODEL_PRESENT; exit 0; fi
    echo PULLING ${model};
    curl -s --max-time 3600 -X POST '${ep}/api/pull' -d '{\"model\":\"${model}\"}' >/dev/null;
    if curl -s --max-time 10 '${ep}/api/tags' | grep -q '\"model\":\"${model}\"'; then
      echo MODEL_PULLED; else echo MODEL_MISSING; exit 1; fi" >/dev/null 2>&1
  $K wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=3600s >/dev/null 2>&1
  local rc=$?
  local out; out="$($K logs "$pod" 2>/dev/null || true)"
  $K delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then
    ok "model '${model}' available on endpoint (${out//$'\n'/ })"
  else
    die "could not ensure model '${model}' on ${ep} (${out//$'\n'/ }).
  Pull it manually or check Ollama egress from the cluster."
  fi
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
  ollama)      resolve_ollama; load_env; ensure_ollama_model ;;
  openai|azureOpenAI) resolve_hosted ;;
  *) die "unknown LLM_PROVIDER '${PROVIDER}' (expected ollama|openai|azureOpenAI)" ;;
esac

load_env
ok "llm-config complete: provider=${PROVIDER} model=${LLM_MODEL:-?} endpoint=${LLM_ENDPOINT:-?}"
