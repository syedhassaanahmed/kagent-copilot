# Troubleshooting

Notes on the tricky parts of this demo: networking between
n8n (Compose) ↔ kagent (Kind) ↔ the host LLM, and small-model behaviour.

## A2A endpoint & wire shape

- **Agent A2A URL:** `http://<host>:<KAGENT_A2A_NODEPORT>/api/a2a/<namespace>/<agent>`
  (default `http://localhost:30883/api/a2a/kagent/a2a-demo-agent`).
- **Agent card:** `…/.well-known/agent-card.json` (HTTP 200). The legacy
  `agent.json` path is no longer used.
- **`message/send`** is JSON-RPC 2.0 (legacy v0, no version header):
  ```json
  {"jsonrpc":"2.0","id":"1","method":"message/send",
   "params":{"message":{"kind":"message","role":"user","messageId":"<uuid>",
   "parts":[{"kind":"text","text":"<prompt>"}]}}}
  ```
  The reply text is in `result.history[]` (role `agent`) and `result.artifacts[]`;
  `result.status.state` is `completed` on success.

## Networking: who can reach the LLM?

The hardest part is getting the **kagent pods** to reach the **host's Ollama**. The
right host address differs per platform, so `scripts/35-llm-config.sh` derives a
candidate set and **probes each from an in-cluster pod** (`GET /api/tags`), writing
the first reachable one to `LLM_ENDPOINT` in `.env`.

| Platform | Pod → host LLM route |
|----------|----------------------|
| Linux / WSL2 (Docker Engine) | Kind docker-network gateway IP (`docker network inspect kind`, e.g. `172.18.0.1`) |
| macOS / Docker Desktop | the IP `host.docker.internal` resolves to from a container, plus the bridge gateway |

### ⚠️ Docker Desktop + WSL2 gotcha (important)

When Docker runs as **Docker Desktop on Windows with a WSL2 backend** (as opposed to
native Docker Engine inside the WSL distro), the host-gateway IP `192.168.65.254`
routes to the **Windows host's** Ollama, **not** the Ollama running inside your WSL
distro. Symptoms:

- The A2A call succeeds at the wire level but the model call fails with
  `model '<name>' not found (404)` — because the Windows-side Ollama has **no models
  pulled**, even though `ollama list` inside WSL shows them.
- The WSL distro IP and the Kind gateway `172.x.0.1` are unreachable / connection-
  refused from pods.

**Fix (already automated):** `35-llm-config.sh` resolves the endpoint that pods can
actually reach, then `ensure_ollama_model` **pulls the model onto that endpoint** via
its REST API (`POST /api/pull`) from inside the cluster — so the model exists exactly
where the pods will look for it. If you switch `LLM_MODEL`, re-run
`make llm-config` (or `make up`) so the new model is pulled to the right place.

To diagnose manually, run a throwaway in-cluster probe:

```bash
kubectl --context kind-kagent-n8n run probe --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s http://<candidate-ip>:11434/api/tags
```

### n8n → kagent

The n8n container reaches the Kind-published NodePort through
`host.docker.internal` thanks to `extra_hosts: ["host.docker.internal:host-gateway"]`
in `n8n/docker-compose.yaml`. The imported A2A credential's `serverUrl` is rendered
from `.env` at import time by `scripts/70-import-workflow.sh`.

## Small-model caveats

Tiny CPU models are convenient but unreliable at structured/tool output:

- **`qwen2.5:1.5b` (default, ~1GB):** reliably returns clean prose over A2A.
- **`llama3.2:1b` (smaller, 1B):** often emits spurious function-call JSON
  (e.g. `{"name":"…","parameters":{…}}`) instead of an answer. Use it only if you
  need the absolute smallest footprint, and expect flaky replies.
- Hosted OpenAI-compatible backends (set `LLM_PROVIDER=openai`/`azureOpenAI`) avoid
  this entirely.

## Common issues

| Symptom | Fix |
|---------|-----|
| `model '<name>' not found (404)` from the agent | Re-run `make llm-config` to pull the model onto the pod-reachable endpoint |
| n8n editor asks to create an owner account | Expected on first launch; create a local account, then open `make open-ui` again |
| `make demo` prints no reply | Run `make status`; ensure the agent is `Ready` and the A2A card returns HTTP 200 |
| A2A node missing in n8n | `make n8n-up` reinstalls `@agentic-layer/n8n-nodes-a2a` and restarts n8n |
| Workflow not in editor | `make workflow` re-imports it (idempotent) |
| Want to reset everything | `make down` then `make up` |

## Handy commands

```bash
make status                       # host / Ollama / Kind / kagent / n8n at a glance
make logs                         # kagent controller + agent + n8n logs
kubectl --context kind-kagent-n8n -n kagent get agent,modelconfig
curl -s http://localhost:30883/api/a2a/kagent/a2a-demo-agent/.well-known/agent-card.json | jq .
```
