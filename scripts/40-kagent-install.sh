#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 40-kagent-install.sh — install kagent (CRDs + controller/UI) via Helm OCI.
#
# Exposes the controller A2A port (8083) on a deterministic NodePort so the
# n8n container can reach it through the Kind host port mapping. The LLM is NOT
# wired here — a provider-agnostic ModelConfig is applied by 50-kagent-agent.
#
# Idempotent: helm upgrade --install + server-side apply of the NodePort svc.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd helm
require_cmd kubectl

CLUSTER="${KIND_CLUSTER_NAME:-kagent-n8n}"
CTX="kind-${CLUSTER}"
K="kubectl --context ${CTX}"
NS="${KAGENT_NAMESPACE:-kagent}"
NODEPORT="${KAGENT_A2A_NODEPORT:-30883}"
KAGENT_VERSION="${KAGENT_VERSION:-0.9.9}"

CRDS_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds"
KAGENT_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent"

# Advertised base URL for the agent card — must be reachable from the n8n
# container (which has host.docker.internal:host-gateway).
A2A_BASE_URL="http://host.docker.internal:${NODEPORT}"

# Built-in demo agents shipped by the chart (k8s/istio/cilium/argo/helm/...).
# This repo provisions its own Agent, so disable them by default to keep the
# cluster lean. Override with KAGENT_DISABLE_BUILTIN_AGENTS=false to keep them.
BUILTIN_AGENTS="k8s-agent kgateway-agent istio-agent promql-agent observability-agent argo-rollouts-agent helm-agent cilium-policy-agent cilium-manager-agent cilium-debug-agent"
disable_args=()
if [ "${KAGENT_DISABLE_BUILTIN_AGENTS:-true}" = "true" ]; then
  for a in $BUILTIN_AGENTS; do
    disable_args+=(--set "${a}.enabled=false")
  done
fi

log "installing kagent CRDs (v${KAGENT_VERSION})..."
helm upgrade --install kagent-crds "$CRDS_CHART" \
  --version "$KAGENT_VERSION" \
  --kube-context "$CTX" \
  --namespace "$NS" --create-namespace \
  --wait --timeout 5m
ok "kagent CRDs installed"

log "installing kagent controller/UI (v${KAGENT_VERSION})..."
# providers.default=ollama avoids the default ModelConfig needing a cloud API
# key; our Agent references its own ModelConfig regardless.
if [ "${#disable_args[@]}" -gt 0 ]; then
  log "disabling built-in demo agents (${BUILTIN_AGENTS// /, })"
fi
helm upgrade --install kagent "$KAGENT_CHART" \
  --version "$KAGENT_VERSION" \
  --kube-context "$CTX" \
  --namespace "$NS" \
  --set providers.default=ollama \
  --set controller.a2aBaseUrl="$A2A_BASE_URL" \
  ${disable_args[@]+"${disable_args[@]}"} \
  --wait --timeout 10m
ok "kagent installed"

# --- wait for the controller deployment ----------------------------------
CTRL_DEPLOY="$($K -n "$NS" get deploy -o name | grep -i controller | head -1 || true)"
[ -n "$CTRL_DEPLOY" ] || die "could not find the kagent controller Deployment"
log "waiting for ${CTRL_DEPLOY} rollout..."
$K -n "$NS" rollout status "$CTRL_DEPLOY" --timeout=300s
ok "controller is ready"

# --- deterministic NodePort for the A2A port -----------------------------
CTRL_SVC="$($K -n "$NS" get svc -o name | grep -i controller | grep -vi metrics | head -1)"
[ -n "$CTRL_SVC" ] || die "could not find the kagent controller Service"
SELECTOR_JSON="$($K -n "$NS" get "$CTRL_SVC" -o jsonpath='{.spec.selector}')"
log "controller service ${CTRL_SVC} selector: ${SELECTOR_JSON}"

# Build selector YAML lines from the controller's selector map.
selector_yaml="$(python3 - "$SELECTOR_JSON" <<'PY'
import json,sys
sel=json.loads(sys.argv[1])
print("\n".join(f"    {k}: {v}" for k,v in sel.items()))
PY
)"

log "applying deterministic A2A NodePort service (nodePort ${NODEPORT} -> 8083)..."
cat <<EOF | $K -n "$NS" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: kagent-a2a-nodeport
  labels:
    app.kubernetes.io/part-of: kagent
    kagent-n8n-demo: "true"
spec:
  type: NodePort
  selector:
${selector_yaml}
  ports:
    - name: a2a
      port: 8083
      targetPort: 8083
      nodePort: ${NODEPORT}
      protocol: TCP
EOF
ok "A2A NodePort service applied"

# --- verify host reachability of the NodePort ----------------------------
# No agent exists yet, so any HTTP response (even 404) proves the port is live.
if wait_for "A2A NodePort on host :${NODEPORT}" 60 bash -c \
     "curl -s -o /dev/null --max-time 5 http://localhost:${NODEPORT}/ && true"; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${NODEPORT}/" || echo 000)"
  ok "A2A NodePort reachable from host (HTTP ${code})"
fi

$K -n "$NS" get pods
ok "kagent-install complete (A2A base: ${A2A_BASE_URL})"
