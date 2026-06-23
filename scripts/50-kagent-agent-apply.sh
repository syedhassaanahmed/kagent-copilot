#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 50-kagent-agent-apply.sh — render & apply the provider-agnostic ModelConfig
# (from .env), the optional API-key Secret, and the demo Agent CR.
#
# .env is the single source of truth (the pluggable LLM backend): change
# LLM_PROVIDER/MODEL/ENDPOINT/API_KEY and re-run to switch backends — no code
# changes. Idempotent via `kubectl apply`.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd kubectl
CLUSTER="${KIND_CLUSTER_NAME:-kagent-copilot}"
CTX="kind-${CLUSTER}"
K="kubectl --context ${CTX}"

NS="${AGENT_NAMESPACE:-kagent}"
AGENT="${AGENT_NAME:-a2a-demo-agent}"
PROVIDER="${LLM_PROVIDER:-ollama}"
MODEL="${LLM_MODEL:-qwen2.5:1.5b}"
ENDPOINT="${LLM_ENDPOINT:-}"
API_KEY="${LLM_API_KEY:-}"
MODELCONFIG_NAME="a2a-demo-modelconfig"
SECRET_NAME="${AGENT}-llm"
SECRET_KEY="API_KEY"

[ -n "$ENDPOINT" ] || die "LLM_ENDPOINT is empty — run 'make llm-config' first"
$K get ns "$NS" >/dev/null 2>&1 || die "namespace ${NS} not found — run 'make kagent-install' first"

# Strip URL scheme for ollama host (kagent expects host:port).
host_no_scheme="${ENDPOINT#http://}"; host_no_scheme="${host_no_scheme#https://}"; host_no_scheme="${host_no_scheme%/}"

# --- optional API-key Secret (hosted providers) --------------------------
if [ "$PROVIDER" != "ollama" ]; then
  [ -n "$API_KEY" ] || warn "LLM_PROVIDER=${PROVIDER} but LLM_API_KEY is empty"
  log "applying API-key Secret ${SECRET_NAME}..."
  $K -n "$NS" create secret generic "$SECRET_NAME" \
    --from-literal="${SECRET_KEY}=${API_KEY}" \
    --dry-run=client -o yaml | $K -n "$NS" apply -f -
fi

# --- render ModelConfig per provider -------------------------------------
log "applying ModelConfig '${MODELCONFIG_NAME}' (provider=${PROVIDER}, model=${MODEL})"
case "$PROVIDER" in
  ollama)
    cat <<EOF | $K -n "$NS" apply -f -
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: ${MODELCONFIG_NAME}
spec:
  provider: Ollama
  model: ${MODEL}
  ollama:
    host: ${host_no_scheme}
    options:
      num_ctx: "8192"
EOF
    ;;
  openai)
    cat <<EOF | $K -n "$NS" apply -f -
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: ${MODELCONFIG_NAME}
spec:
  provider: OpenAI
  model: ${MODEL}
  apiKeySecret: ${SECRET_NAME}
  apiKeySecretKey: ${SECRET_KEY}
  openAI:
    baseUrl: ${ENDPOINT}
EOF
    ;;
  azureOpenAI)
    cat <<EOF | $K -n "$NS" apply -f -
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: ${MODELCONFIG_NAME}
spec:
  provider: AzureOpenAI
  model: ${MODEL}
  apiKeySecret: ${SECRET_NAME}
  apiKeySecretKey: ${SECRET_KEY}
  azureOpenAI:
    azureEndpoint: ${ENDPOINT}
    azureDeployment: ${MODEL}
    apiVersion: "${AZURE_API_VERSION:-2024-10-21}"
EOF
    ;;
  *) die "unknown LLM_PROVIDER '${PROVIDER}'" ;;
esac
ok "ModelConfig applied"

# --- render Agent from kagent/agent.yaml ---------------------------------
log "applying Agent '${AGENT}' in namespace '${NS}'..."
sed -e "s|\${AGENT_NAME}|${AGENT}|g" \
    -e "s|\${AGENT_NAMESPACE}|${NS}|g" \
    -e "s|\${MODELCONFIG_NAME}|${MODELCONFIG_NAME}|g" \
    "$REPO_ROOT/kagent/agent.yaml" | $K apply -f -
ok "Agent applied"

# --- wait for readiness --------------------------------------------------
log "waiting for Agent '${AGENT}' to become Ready..."
if $K -n "$NS" wait --for=condition=Ready "agent/${AGENT}" --timeout=180s 2>/dev/null; then
  ok "Agent '${AGENT}' is Ready"
else
  warn "Agent not Ready within timeout; recent status:"
  $K -n "$NS" get agent "$AGENT" -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}' || true
  die "Agent '${AGENT}' did not become Ready"
fi

$K -n "$NS" get agent "$AGENT"
$K -n "$NS" get modelconfig "$MODELCONFIG_NAME"
ok "kagent-agent complete — A2A path: /api/a2a/${NS}/${AGENT}"
