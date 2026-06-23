# Copilot Studio A2A integration

This directory contains the Microsoft Copilot Studio-side templates for connecting a host agent to the local kagent A2A demo agent through a public Microsoft Dev Tunnel.

## Contents

- `connector/apiDefinition.json` — Swagger 2.0 custom connector template for the A2A `message/send` endpoint. It uses placeholders for the tunnel host and kagent A2A path.
- `connector/apiProperties.json` — Custom connector properties template. The tunnel endpoint is anonymous, so `connectionParameters` is intentionally empty for Authentication = None.
- `agent/instructions.md` — Concise host-agent instructions to paste into, or deploy to, the Copilot Studio host agent.

## Automated deploy

`scripts/60-copilot-deploy.sh` renders the connector template before deployment:

- `__TUNNEL_HOST__` → the resolved tunnel host from `TUNNEL_URL`
- `__A2A_NAMESPACE__` → `$KAGENT_NAMESPACE`
- `__A2A_AGENT__` → `$AGENT_NAME`

The script then deploys the Copilot Studio host agent, custom connector, and connection with `pac`, and publishes the host agent with `pac copilot publish`. The connector and host agent are packaged in the `$COPILOT_SOLUTION_NAME` solution so deploy and teardown can be idempotent.

## Manual maker-portal fallback

If automated deployment is unavailable, perform this one-time setup in the maker portal:

1. Open the host agent.
2. Go to **Agents** → **Add agent** → **A2A agent**.
3. Paste the message endpoint URL: `https://<tunnel-host>/api/a2a/<namespace>/<agent>`.
4. Set **Authentication** to **None**.
5. Save the connected agent.
6. **Publish** the host agent (click the **Publish** button in the portal).

The host agent **must be Published** before testing. If it is not published, every Test run can fail with a generic `SystemError` and no A2A traffic will reach kagent.

## Agent card protocol version

Copilot Studio's A2A bind flow currently supports **A2A protocol v0.3 agent cards only**. kagent **0.9.7+** migrated its card to A2A v1 (it adds a `supportedInterfaces` array with a `protocolVersion: "1.0"` entry); the maker portal rejects that with *"This agent card uses A2A protocol v1, which is not supported yet. Please use an agent that provides a v0.3 agent card."*

This demo therefore **pins `KAGENT_VERSION=0.9.6`** (in `scripts/40-kagent-install.sh`), the last release that serves a pure v0.3 card. With 0.9.6 the maker portal binds the A2A agent and auto-populates its name and description. If you override the version to 0.9.7 or later, expect the bind step to fail until Copilot Studio adds A2A v1 support.

## Optional interactive plugin

The optional `microsoft/skills-for-copilot-studio` plugin for Claude Code or GitHub Copilot CLI can be used interactively to author, test, and troubleshoot the host agent. Its manage, author, test, and advisor sub-agents are useful while iterating on the Copilot Studio configuration.
