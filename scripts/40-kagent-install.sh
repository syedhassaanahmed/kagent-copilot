#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 40-kagent-install.sh — install kagent (CRDs + controller/UI) via Helm OCI.
#
# Exposes the controller A2A port (8083) on a deterministic NodePort so a
# Microsoft Copilot Studio agent can reach it through a dev tunnel. The LLM is
# NOT wired here — a provider-agnostic ModelConfig is applied by 50-kagent-agent.
#
# Idempotent: helm upgrade --install + server-side apply of the NodePort svc.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd helm
require_cmd kubectl

CLUSTER="${KIND_CLUSTER_NAME:-kagent-copilot}"
CTX="kind-${CLUSTER}"
K="kubectl --context ${CTX}"
NS="$(kagent_namespace)"
NODEPORT="${KAGENT_A2A_NODEPORT:-30883}"
# Pinned to 0.9.6 — the last kagent release that serves a pure A2A v0.3 agent card.
# kagent 0.9.7+ (commit "Migrate from A2A v0 to v1") adds a `supportedInterfaces`
# array with a protocolVersion "1.0" entry to the card. Copilot Studio's A2A bind
# flow ("Add agent -> A2A agent") rejects that as "A2A protocol v1, which is not
# supported yet. Please use an agent that provides a v0.3 agent card." Verified by
# hand: 0.9.7+ cards fail to bind, 0.9.6 cards bind and auto-populate name/desc.
KAGENT_VERSION="${KAGENT_VERSION:-0.9.6}"

CRDS_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds"
KAGENT_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent"

# Advertised base URL for the agent card. Copilot Studio fetches the card at
# {a2aBaseUrl}/.well-known/agent-card.json and POSTs A2A messages to
# {a2aBaseUrl}/api/a2a/<ns>/<agent>, so this MUST be the public Dev Tunnel HTTPS
# URL resolved by 25-devtunnel-up.sh (written to .env as TUNNEL_URL). If TUNNEL_URL
# is unset we fall back to the host-routable local URL so a kagent-only bring-up
# still works (the tunnel/Copilot path just won't be reachable from the cloud).
if [ -n "${TUNNEL_URL:-}" ]; then
  A2A_BASE_URL="${TUNNEL_URL%/}"
  ok "agent card a2aBaseUrl = ${A2A_BASE_URL} (Dev Tunnel)"
else
  A2A_BASE_URL="http://host.docker.internal:${NODEPORT}"
  warn "TUNNEL_URL not set — using local a2aBaseUrl ${A2A_BASE_URL}; run 25-devtunnel-up.sh first so Copilot Studio can reach kagent"
fi

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
  --wait --timeout 10m && helm_rc=0 || helm_rc=$?
if [ "${helm_rc:-0}" -eq 0 ]; then
  ok "kagent installed"
else
  # The controller runs DB migrations on startup and crash-loops until the
  # chart's PostgreSQL accepts connections. On a cold cluster that backoff can
  # outlast helm's --wait window, marking the release 'failed' even though it
  # recovers. Tolerate that here and reconcile readiness explicitly below.
  warn "helm --wait did not converge (rc=${helm_rc}); the controller likely crash-looped waiting for PostgreSQL — reconciling readiness..."
fi

# --- wait for the controller deployment ----------------------------------
CTRL_DEPLOY="$($K -n "$NS" get deploy -o name | grep -i 'controller' | grep -viE 'kmcp|manager' | head -1 || true)"
[ -n "$CTRL_DEPLOY" ] || die "could not find the kagent controller Deployment"

# The controller can only finish its migrations once PostgreSQL is up, so wait
# for postgres first to avoid chasing the controller's crash-loop backoff.
PG_DEPLOY="$($K -n "$NS" get deploy -o name | grep -i postgres | head -1 || true)"
if [ -n "$PG_DEPLOY" ]; then
  log "waiting for ${PG_DEPLOY} rollout..."
  $K -n "$NS" rollout status "$PG_DEPLOY" --timeout=300s || true
fi

log "waiting for ${CTRL_DEPLOY} rollout..."
if ! $K -n "$NS" rollout status "$CTRL_DEPLOY" --timeout=600s; then
  # Still not ready — likely stuck in crash-loop backoff from the cold-start race
  # with PostgreSQL. Restart it to retry immediately instead of waiting out the
  # exponential backoff.
  warn "${CTRL_DEPLOY} not ready yet — restarting to clear crash-loop backoff..."
  $K -n "$NS" rollout restart "$CTRL_DEPLOY"
  $K -n "$NS" rollout status "$CTRL_DEPLOY" --timeout=300s
fi
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
    kagent-copilot-demo: "true"
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
  code="$(http_code "http://localhost:${NODEPORT}/" --max-time 5)"
  ok "A2A NodePort reachable from host (HTTP ${code})"
fi

$K -n "$NS" get pods
ok "kagent-install complete (A2A base: ${A2A_BASE_URL})"
