# kagent-copilot A2A demo

Demonstrates a **Microsoft Copilot Studio agent** (cloud A2A client / orchestrator) talking to a **local kagent-based agent** over the **A2A (Agent-to-Agent) protocol**. kagent runs in a Kind Kubernetes cluster as the A2A **server** and is exposed to Copilot Studio over the public internet with **Microsoft Dev Tunnels**. The Copilot Studio side is automated with the **Power Platform CLI (`pac`)**.

> Full design and task breakdown live in [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md).

## Architecture

```text
┌────────────────────┐  A2A (JSON-RPC)  ┌───────────────┐  HTTPS  ┌──────────────┐ NodePort ┌──────────────┐  asks  ┌──────────┐
│  Copilot Studio    │ ───────────────▶ │  Dev Tunnel   │ ──────▶ │ host :30883  │ ───────▶ │   kagent     │ ─────▶ │   LLM    │
│  agent (cloud,     │  /api/a2a/...    │ public HTTPS  │         │ (Kind map)   │          │  agent (A2A  │        │ (Ollama/ │
│  A2A orchestrator) │ ◀─────────────── │   endpoint    │ ◀────── │              │ ◀─────── │   server)    │ ◀───── │ OpenAI)  │
└────────────────────┘      reply       └───────────────┘         └──────────────┘          └──────────────┘ answer └──────────┘
        Microsoft cloud         devtunnel host (persistent, anon)     local Kind cluster              local/hosted model
```

- **Copilot Studio is the A2A client/orchestrator; kagent is the A2A server.** Copilot Studio fetches kagent's agent card and POSTs `message/send` requests to it through the tunnel.
- kagent's `controller.a2aBaseUrl` is set to the **Dev Tunnel HTTPS URL** so the agent card advertises a publicly reachable endpoint.
- The endpoint you give Copilot Studio is the **A2A message endpoint**: `https://<tunnel-host>/api/a2a/<namespace>/<agent>` (default path `/api/a2a/kagent/a2a-demo-agent`).
- Copilot Studio never talks to the LLM directly — all inference happens inside the kagent agent via its `ModelConfig`.

## Prerequisites

- A Unix-like host: **Linux, WSL2, or macOS** (Intel or Apple Silicon).
- **Docker** (Engine on Linux/WSL2, Docker Desktop on macOS) running.
- `make`, `bash`, `curl`. The remaining CLIs are installed idempotently by `make tools`:
  `kubectl`, `kind`, `helm`, `ollama`, **`devtunnel`** (Microsoft Dev Tunnels), and **`pac`** (Power Platform CLI). `pac` needs the **.NET SDK** (8+) plus two native packages on Linux/WSL2: **`libicu`** (ICU, for .NET globalization) and **`xdg-utils`** (provides `xdg-open` for browser-based `pac auth`). On Debian/Ubuntu: `sudo apt-get install -y libicu-dev xdg-utils`.
- A **Microsoft Dev Tunnels** login (`devtunnel user login`, one-time).
- A signed-in **`pac`** profile (`pac auth create --url <env-url>`; `make copilot` will prompt if none exists). An active profile is also what lets `PAC_ENVIRONMENT_URL` auto-resolve.
- A **Power Platform environment** where you can create agents and connections — i.e. a Copilot Studio license and the **edit-agents** + **configure-connections** permissions. Set its Dataverse URL in `PAC_ENVIRONMENT_URL`, or leave it blank to auto-use the environment of your active `pac` auth profile (`pac org list` shows the URL).

## Quickstart

```bash
cp .env.example .env          # optional; scripts auto-create .env on first run
# optional: set PAC_ENVIRONMENT_URL in .env to target a specific environment
#           (blank = auto-use your active `pac` auth profile)

make up                       # kagent + persistent Dev Tunnel (local A2A server, exposed)
make copilot                  # deploy + publish the Copilot Studio host agent via pac
make demo                     # open the kagent UI + the Copilot Studio maker portal (Test pane)
make down                     # tear down everything (cluster, tunnel, Copilot Studio, Ollama)
```

Run `make help` to list all targets.

## Make targets

| Target | What it does |
|--------|--------------|
| `make up` | Idempotent bring-up: preflight → tools → ollama → kind → **devtunnel** → llm-config → kagent-install → agent → verify-a2a |
| `make devtunnel` | Create/host the persistent Dev Tunnel and resolve `TUNNEL_URL` (runs **before** kagent-install) |
| `make copilot` | Deploy + publish the Copilot Studio host agent and A2A custom connector via `pac` |
| `make demo` | Open the kagent UI and the Copilot Studio maker portal (prints the A2A endpoint + a prompt to paste into the Test pane) |
| `make status` | Status of cluster, kagent, Dev Tunnel and Power Platform auth |
| `make logs` | Tail kagent controller / agent / devtunnel host logs (`TARGET=kagent\|agent\|tunnel`) |
| `make down` | Tear down **everything** (idempotent; skips whatever is absent): cluster, tunnel (deleted), Copilot Studio, Ollama |
| `make clean-copilot` | Tear down **only** the Copilot Studio footprint (solution, connector, connection) |
| `make help` | List all targets |

## Configuration

All configuration lives in `.env` (created from `.env.example`). Key knobs:

| Key | Purpose |
|-----|---------|
| `LLM_PROVIDER` | `ollama` (default) \| `openai` \| `azureOpenAI` |
| `LLM_MODEL` | model / deployment name (default `qwen2.5:1.5b`) |
| `LLM_ENDPOINT` / `LLM_API_KEY` | LLM base URL + key for hosted providers (blank for ollama) |
| `KAGENT_A2A_NODEPORT` | host NodePort for the A2A endpoint (default `30883`) |
| `TUNNEL_NAME` | persistent Dev Tunnel id (stable public URL) |
| `TUNNEL_URL` | resolved by `make devtunnel` — written back to `.env` |
| `PAC_ENVIRONMENT_URL` | Dataverse environment URL for `pac auth create`; blank = auto-use the active `pac` profile (`pac org who`) |
| `COPILOT_AGENT_DISPLAY_NAME` / `COPILOT_AGENT_SCHEMA_NAME` | host-agent display + schema name (idempotent reuse) |
| `COPILOT_SOLUTION_NAME` | Dataverse solution packaging the host agent + connector |

The LLM is a **kagent concern only**. Copilot Studio sends A2A requests; kagent performs inference through its `ModelConfig`.

## Demo walkthrough

1. `make up` — brings up kagent, creates + hosts the persistent Dev Tunnel, sets the agent card's `a2aBaseUrl` to the tunnel URL, and verifies the agent card + `message/send` **through the public tunnel**.
2. `make copilot` — authenticates `pac` against `PAC_ENVIRONMENT_URL` (or your active `pac` profile's environment when it's blank), renders the A2A connector to your tunnel host, deploys the host agent + connector, and **publishes** the agent. (Publishing is required — an unpublished agent throws `SystemError` on every test.)
3. One-time bind: in the maker portal follow the printed **Agents → Add agent → A2A agent** steps (endpoint + Auth = None), then click **Publish** so the binding goes live. See [`copilot/README.md`](./copilot/README.md).
4. `make demo` — opens the kagent UI and the Copilot Studio maker portal and prints the A2A endpoint + a test prompt. Send the prompt in your host agent's **Test** pane and watch it delegate to kagent. Tail `make logs TARGET=tunnel` / `make logs TARGET=agent` to see the A2A request arrive.
5. `make down` tears everything down; re-running `make up` is idempotent.

> **Optional:** the [`microsoft/skills-for-copilot-studio`](https://github.com/microsoft/skills-for-copilot-studio) plugin can author/test the host agent interactively. It is additive — the scripted `pac` path here does not require it.

See [`docs/troubleshooting.md`](./docs/troubleshooting.md) for Dev Tunnels, Power Platform, streaming, and small-model notes.

## License

Released under the [MIT License](./LICENSE).
