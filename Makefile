# ===========================================================================
# kagent-copilot A2A demo — orchestration Makefile
# Targets wrap the idempotent scripts in scripts/. Safe to re-run.
# ===========================================================================
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

S := scripts

.PHONY: help up demo status logs down \
        preflight tools ollama kind devtunnel llm-config kagent-install kagent-agent \
        verify-a2a copilot \
        clean-copilot

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "\nkagent-copilot A2A demo — make targets\n\n"} \
	     /^[a-zA-Z0-9_-]+:.*##/{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""

# --- end-to-end -----------------------------------------------------------
up: preflight tools ollama kind devtunnel llm-config kagent-install kagent-agent verify-a2a ## Bring up kagent + the public Dev Tunnel (local A2A server, tunnel-exposed)
	@echo "kagent A2A server is up and exposed via Dev Tunnel. Run 'make copilot' to deploy the Copilot Studio host agent."

demo: ## Open the kagent UI + the Copilot Studio maker portal (with the A2A endpoint + test prompt to paste into the Test pane)
	@bash $(S)/95-open-ui.sh

status: ## Show status of cluster, kagent, Dev Tunnel and Power Platform auth
	@bash $(S)/98-status.sh

logs: ## Tail kagent controller + agent + devtunnel host logs (TARGET=kagent|agent|tunnel optional)
	@bash $(S)/97-logs.sh $(TARGET)

down: ## Tear down EVERYTHING (idempotent; skips whatever is absent): cluster, tunnel (+delete), Copilot Studio, Ollama model
	@bash $(S)/99-teardown.sh --all

# --- individual steps (local kagent + tunnel) -----------------------------
preflight: ## Detect OS/arch, verify Docker, and check devtunnel/pac + logins
	@bash $(S)/00-preflight.sh

tools: ## Install kubectl, kind, helm, ollama, devtunnel and pac
	@bash $(S)/10-install-tools.sh

ollama: ## (ollama provider) start ollama on 0.0.0.0 and pull the model
	@bash $(S)/20-ollama-up.sh

kind: ## Create the Kind cluster with A2A NodePort mappings
	@bash $(S)/30-kind-up.sh

devtunnel: ## Create/host the persistent Dev Tunnel and resolve TUNNEL_URL (before kagent-install)
	@bash $(S)/25-devtunnel-up.sh

llm-config: ## Resolve/verify the LLM endpoint reachable from the cluster
	@bash $(S)/35-llm-config.sh

kagent-install: ## Install kagent CRDs + controller/UI (a2aBaseUrl = TUNNEL_URL)
	@bash $(S)/40-kagent-install.sh

kagent-agent: ## Apply the ModelConfig + Agent CRs
	@bash $(S)/50-kagent-agent-apply.sh

verify-a2a: ## Smoke-test the A2A agent card + message/send (local and via the tunnel)
	@bash $(S)/55-verify-a2a.sh

# --- Copilot Studio (cloud) side ------------------------------------------
copilot: ## Deploy + publish the Copilot Studio host agent and A2A connector via pac
	@bash $(S)/60-copilot-deploy.sh

# --- teardown -------------------------------------------------------------
clean-copilot: ## Tear down ONLY the Copilot Studio footprint (solution, connector, connection)
	@bash $(S)/99-teardown.sh --copilot
