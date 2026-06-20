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
| Linux (native Docker Engine) | Kind docker-network gateway IP (`docker network inspect kind`, e.g. `172.18.0.1`) |
| WSL2 / macOS (Docker Desktop) | Windows/VM host gateway `host.docker.internal` → `192.168.65.254` (IPv4); on WSL2 the stock dual-stack Ollama must be **bound to IPv4** (`OLLAMA_HOST=127.0.0.1`, applied by `make up`) — see the gotcha below |

### ⚠️ Docker Desktop + WSL2 gotcha (important): stock Ollama is dual-stack

When Docker runs as **Docker Desktop on Windows with a WSL2 backend** (as opposed to
native Docker Engine inside the WSL distro), Kind pods reach the host only through the
**Windows host gateway `192.168.65.254`**, which lands on the **Windows IPv4 loopback**.
WSL2's localhost mirror then forwards that loopback to your WSL services — **but only
for IPv4-bound sockets**. Docker Desktop's default networking is **IPv4-only**.

Stock Ollama binds **dual-stack IPv6 `[::]:11434`** — `ss -ltn` shows it as `*:11434` —
**even when you set `OLLAMA_HOST=0.0.0.0:11434`**. The WSL2 mirror does **not** forward
that IPv6 socket, so the IPv4-only Kind pods cannot reach it.

**Symptom:** the A2A call succeeds at the wire level, but the agent's model call hangs
or fails because the pod cannot open a connection to `192.168.65.254:11434`. A pod
probe of `192.168.65.254:11434` returns `000`/timeout while `curl localhost:11434`
works fine inside WSL.

**Root cause (validated):**

| Ollama bind | `ss` shows | Pod → `192.168.65.254:port` |
|-------------|-----------|------------------------------|
| `0.0.0.0:port` (true IPv4) | `0.0.0.0:port` | ✅ HTTP 200 |
| `127.0.0.1:port` (IPv4 loopback) | `127.0.0.1:port` | ✅ HTTP 200 |
| `0.0.0.0` *as Ollama interprets it* | `*:port` (dual-stack) | ❌ unreachable |
| `[::]:port` (IPv6) | `[::]:port` / `*:port` | ❌ unreachable |

**Fix (recommended — keeps the default port 11434): bind Ollama to IPv4.**
Force Ollama onto an explicit IPv4 socket with `OLLAMA_HOST=127.0.0.1:11434`, which
the WSL2 NAT-mode mirror *does* forward. For the systemd-managed Ollama, apply a
drop-in once (this is exactly what `make ollama` / `make up` applies automatically,
prompting for `sudo` when needed):

```bash
sudo rm -f /etc/systemd/system/ollama.service.d/ipv4.conf
sudo mkdir -p /etc/systemd/system/ollama.service.d && \
printf '[Service]\nEnvironment="OLLAMA_HOST=127.0.0.1:11434"\n' \
  | sudo tee /etc/systemd/system/ollama.service.d/zz-ipv4.conf && \
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

> **Drop-in ordering gotcha:** the stock installer (or a prior `systemctl edit
> ollama`) often leaves an `override.conf` with `OLLAMA_HOST=0.0.0.0:11434`. systemd
> merges `*.service.d/*.conf` **alphabetically** and the *last* assignment of a
> variable wins, so a drop-in named `ipv4.conf` would be overridden by
> `override.conf`. Name it `zz-ipv4.conf` (sorts last) so the IPv4 bind reliably
> wins. Confirm with `systemctl show ollama -p Environment | tr ' ' '\n' | grep OLLAMA_HOST`.

Afterwards `ss -ltn | grep 11434` should show `127.0.0.1:11434` (not `*:11434`).
`127.0.0.1` is sufficient — only the WSL2 mirror (and through it the pods) needs to
reach Ollama; n8n talks to the kagent NodePort, never to Ollama directly.
`scripts/35-llm-config.sh` then re-probes pod→host reachability and proceeds.

**What does NOT help:** switching Docker Desktop to dual IPv4/IPv6 *alone* (the WSL2
NAT-mode mirror still won't forward the IPv6/localhost hop into WSL); the Docker
Desktop "*.docker.internal in /etc/hosts" setting; restarting/reinstalling Ollama;
rebooting; or `OLLAMA_HOST=0.0.0.0` (Ollama still binds dual-stack `[::]`).

**No-Ollama-change alternative: WSL mirrored networking.** Switch WSL2 from its
default NAT networking to **mirrored** mode, which shares the Windows network stack
(localhost + IPv6) with your WSL distro, so the stock dual-stack Ollama becomes
reachable via `host.docker.internal`:

```ini
# Windows: %UserProfile%\.wslconfig
[wsl2]
networkingMode=mirrored
```

Then from Windows run `wsl --shutdown`, restart, and `make up` again. Requires
**Windows 11 22H2+ (build 22621.2359+)** and **Docker Desktop 4.19+**.

**Fix (model placement, already automated):** `35-llm-config.sh` resolves the endpoint
that pods can reach, and `ensure_model_on_local_ollama` **pulls the model onto the
LOCAL WSL Ollama** (`127.0.0.1:11434`) via its REST API (`POST /api/pull`) — so the
model exists exactly where the pods will look. If you switch `LLM_MODEL`, re-run
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
