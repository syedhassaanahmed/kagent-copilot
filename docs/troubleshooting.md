# Troubleshooting

Notes on the tricky parts of this demo: Copilot Studio → Microsoft Dev Tunnels → kagent (Kind) → host/hosted LLM, plus small-model behaviour.

## A2A endpoint & wire shape

- **Local agent A2A URL:** `http://<host>:<KAGENT_A2A_NODEPORT>/api/a2a/<namespace>/<agent>` (default `http://localhost:30883/api/a2a/kagent/a2a-demo-agent`).
- **Copilot Studio URL:** the Microsoft Dev Tunnel HTTPS URL mapped to the local A2A NodePort, with the same `/api/a2a/<namespace>/<agent>` path.
- **Agent card:** `…/.well-known/agent-card.json` (HTTP 200). The legacy `agent.json` path is no longer used.
- **`message/send`** is JSON-RPC 2.0:
  ```json
  {"jsonrpc":"2.0","id":"1","method":"message/send",
   "params":{"message":{"kind":"message","role":"user","messageId":"<uuid>",
   "parts":[{"kind":"text","text":"<prompt>"}]}}}
  ```
  The reply text is in `result.history[]` (role `agent`) and `result.artifacts[]`; `result.status.state` is `completed` on success.

## Networking: who can reach the LLM?

The hardest local piece is getting the **kagent pods** to reach the **host's Ollama**. The right host address differs per platform, so `scripts/35-llm-config.sh` derives a candidate set and **probes each from an in-cluster pod** (`GET /api/tags`), writing the first reachable one to `LLM_ENDPOINT` in `.env`.

| Platform | Pod → host LLM route |
|----------|----------------------|
| Linux (native Docker Engine) | Kind docker-network gateway IP (`docker network inspect kind`, e.g. `172.18.0.1`) |
| WSL2 / macOS (Docker Desktop) | Host gateway `host.docker.internal` / Docker Desktop VM gateway; on WSL2 the stock dual-stack Ollama must be **bound to IPv4** (`OLLAMA_HOST=127.0.0.1`) |

### Docker Desktop + WSL2 gotcha: stock Ollama is dual-stack

When Docker runs as **Docker Desktop on Windows with a WSL2 backend**, Kind pods reach the host through the Windows host gateway. WSL2's localhost mirror forwards that loopback to WSL services only for IPv4-bound sockets. Stock Ollama often binds dual-stack IPv6 (`[::]:11434`), which IPv4-only Kind pods cannot reach.

**Fix:** force Ollama onto an explicit IPv4 socket with `OLLAMA_HOST=127.0.0.1:11434`. `make ollama` / `make up` applies the systemd drop-in automatically when needed.

To diagnose manually:

```bash
kubectl --context kind-kagent-copilot run probe --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s http://<candidate-ip>:11434/api/tags
```

## Copilot Studio → kagent through Dev Tunnels

1. Confirm local kagent is healthy and exposed through the tunnel:
   ```bash
   make verify-a2a        # checks the card + message/send LOCALLY and via TUNNEL_URL
   make status            # shows TUNNEL_URL, host-process state, and the card HTTP code via the tunnel
   ```
2. `make devtunnel` creates a **persistent named** tunnel (`TUNNEL_NAME`), forwards the A2A NodePort (`30883`), hosts it `--allow-anonymous` (Copilot Studio connects with Auth = None), resolves the public HTTPS URL, and writes it to `TUNNEL_URL` in `.env`. It runs **before** `kagent-install` so the agent card advertises the tunnel URL.
3. The endpoint you give Copilot Studio is `https://<tunnel-host>/api/a2a/<namespace>/<agent>`.

**Ordering matters:** the tunnel URL must exist before kagent install (it becomes `controller.a2aBaseUrl`). The persistent named tunnel gives a stable URL up front, so `make up` runs `devtunnel` before `kagent-install`.

**Anti-phishing interstitial:** Dev Tunnels show an HTML interstitial only to browser `text/html` GETs. A2A traffic (JSON `GET`/`POST`) returns JSON directly. The scripts still send `X-Tunnel-Skip-AntiPhishing-Page: true` on tunnel checks as a belt-and-braces safety net.

If Copilot Studio cannot connect: confirm the `devtunnel host` process is up (`make status` / `make logs TARGET=tunnel`), the URL includes the `/api/a2a/<namespace>/<agent>` path, and `make verify-a2a` still passes through the tunnel.

## Copilot Studio host agent (Power Platform / `pac`)

`make copilot` (`scripts/60-copilot-deploy.sh`) authenticates `pac` against `PAC_ENVIRONMENT_URL`, renders the committed A2A connector template (`copilot/connector/*.json`) to your tunnel host, deploys the host agent + connector packaged in `COPILOT_SOLUTION_NAME`, and runs `pac copilot publish`.

- **You must be Published before testing.** An unpublished host agent throws a generic `SystemError` on every Test message and emits no A2A traffic. After Publish, delegation succeeds.
- **Agent card must be A2A v0.3.** Copilot Studio's "Add agent → A2A agent" flow only accepts **v0.3** agent cards. kagent **0.9.7+** serves an A2A v1 card (adds a `supportedInterfaces` array with a `protocolVersion: "1.0"` entry) and the portal rejects it with *"This agent card uses A2A protocol v1, which is not supported yet. Please use an agent that provides a v0.3 agent card."* The demo pins **`KAGENT_VERSION=0.9.6`** (last pure-v0.3 release) in `scripts/40-kagent-install.sh`; with 0.9.6 the bind succeeds and name/description auto-populate. See [`copilot/README.md`](../copilot/README.md).
- **`pac` install prerequisites.** `pac` is a .NET global tool — it needs the **.NET SDK** (8+) and, on Linux/WSL2, the native packages **`libicu`** (ICU; without it `pac` fails to start with a globalization/ICU error) and **`xdg-utils`** (provides `xdg-open`, which `pac auth create` uses to open the browser). Install with `sudo apt-get install -y libicu-dev xdg-utils` on Debian/Ubuntu.
- **`pac` connector/connection limits (validated live):** `pac connector` has **no delete**, and `pac connection delete` is **broken in default environments**. Teardown therefore deletes the **solution** (`pac solution delete`, removes host agent + connector) and removes the leftover connection via the **PowerApps API**. `make clean-copilot` / `make down` handle this.
- **Streaming negotiation.** Because the agent card advertises `capabilities.streaming:false`, the live Copilot Studio runtime sends non-streaming `method:"message/send"` (JSON-RPC 2.0, `params.message.parts[].text`) even while sending `Accept: text/event-stream`. This matches what `make verify-a2a` sends — **kagent needs no wire changes**.
- **Chat history.** Copilot Studio includes `contextId` + the full chat history under `metadata["copilotstudio.microsoft.com/a2a/chathistory"]`; kagent only reads the latest user message parts, so no kagent change is needed.

## Verifying the cloud round-trip

After deploying (`make copilot`), binding the A2A agent, and **Publishing**, send a prompt in the host agent's **Test** pane (`make demo` opens it). To confirm delegation actually reached kagent, watch its logs while you send the prompt — a fresh A2A `message/send` should appear:

```bash
make logs TARGET=agent
make logs TARGET=tunnel
```

## Small-model caveats

Tiny CPU models are convenient but unreliable at structured/tool output:

- **`qwen2.5:1.5b` (default, ~1GB):** reliably returns clean prose over A2A.
- **`llama3.2:1b` (smaller, 1B):** often emits spurious function-call JSON instead of an answer.
- Hosted OpenAI-compatible backends (set `LLM_PROVIDER=openai`/`azureOpenAI`) avoid this entirely.

## Common issues

| Symptom | Fix |
|---------|-----|
| `model '<name>' not found (404)` from the agent | Re-run `make llm-config` to pull the model onto the pod-reachable endpoint |
| Local A2A card is not HTTP 200 | Run `make status`; ensure the Kind cluster exists and the Agent is Ready |
| Copilot Studio gets connection errors | Check `make status` / `make logs TARGET=tunnel`; test the public agent-card URL with `curl` |
| Copilot Studio Test throws `SystemError` | The host agent is not Published — click **Publish** in the maker portal (or re-run `make copilot`) |
| Portal rejects the A2A agent as "protocol v1 / use v0.3" | kagent 0.9.7+ serves a v1 card — the demo pins `KAGENT_VERSION=0.9.6` (pure v0.3); re-run `make kagent-install` |
| Test pane returns no kagent reply | Run `make verify-a2a`; confirm the A2A agent is bound and **Published** in the portal; inspect `make logs` |
| Want to reset everything | `make down` (idempotent — removes cluster, tunnel, Copilot Studio footprint, Ollama), then `make up` |

## Handy commands

```bash
make status
make logs
make demo
kubectl --context kind-kagent-copilot -n kagent get agent,modelconfig
curl -s http://localhost:30883/api/a2a/kagent/a2a-demo-agent/.well-known/agent-card.json

# Open just the kagent UI manually (Ctrl-C to stop the forward):
kubectl --context kind-kagent-copilot -n kagent port-forward svc/kagent-ui 8080:8080
# then browse http://localhost:8080
```
