#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 60-copilot-deploy.sh — deploy the Copilot Studio host agent + A2A connector.
#
# Renders the committed A2A custom-connector templates with the live Dev Tunnel
# host, upserts the connector and host agent into the configured Dataverse
# environment, then publishes the host agent. Idempotent.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

require_cmd pac

PAC_ENVIRONMENT_URL="${PAC_ENVIRONMENT_URL:-}"
TUNNEL_URL="${TUNNEL_URL:-}"
if [ -z "$PAC_ENVIRONMENT_URL" ]; then
  # Not set in .env — fall back to the active pac auth profile's environment.
  PAC_ENVIRONMENT_URL="$(pac_env_url || true)"
  if [ -n "$PAC_ENVIRONMENT_URL" ]; then
    log "PAC_ENVIRONMENT_URL not set — using the active pac profile's environment"
    upsert_env PAC_ENVIRONMENT_URL "$PAC_ENVIRONMENT_URL"
  fi
fi
[ -n "$PAC_ENVIRONMENT_URL" ] || die "PAC_ENVIRONMENT_URL is empty and no active pac profile found — set it in .env (see 'pac org list') or run 'pac auth create --url <env-url>'"
[ -n "$TUNNEL_URL" ] || die "TUNNEL_URL is empty — run 25-devtunnel-up.sh first (need the public tunnel host for the connector)"

AGENT_NAMESPACE="${AGENT_NAMESPACE:-${KAGENT_NAMESPACE:-kagent}}"
AGENT_NAME="${AGENT_NAME:-a2a-demo-agent}"
COPILOT_AGENT_DISPLAY_NAME="${COPILOT_AGENT_DISPLAY_NAME:-kagent A2A Host}"
COPILOT_AGENT_SCHEMA_NAME="${COPILOT_AGENT_SCHEMA_NAME:-kagent_a2a_host}"
COPILOT_SOLUTION_NAME="${COPILOT_SOLUTION_NAME:-kagentcopilota2a}"
COPILOT_PUBLISHER_PREFIX="${COPILOT_PUBLISHER_PREFIX:-kagent}"
CONNECTOR_DISPLAY_NAME="${COPILOT_CONNECTOR_DISPLAY_NAME:-kagent A2A Demo Agent}"

TUNNEL_BASE="${TUNNEL_URL%/}"
TUNNEL_HOST="${TUNNEL_BASE#http://}"
TUNNEL_HOST="${TUNNEL_HOST#https://}"
TUNNEL_HOST="${TUNNEL_HOST%%/*}"
A2A_ENDPOINT="${TUNNEL_BASE}/api/a2a/${AGENT_NAMESPACE}/${AGENT_NAME}"
[ -n "$TUNNEL_HOST" ] || die "could not derive TUNNEL_HOST from TUNNEL_URL='${TUNNEL_URL}'"

sed_escape() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

find_auth_index() {
  pac auth list 2>/dev/null | awk -v url="$PAC_ENVIRONMENT_URL" 'index($0, url) > 0 { gsub(/[][]/, "", $1); print $1; exit }'
}

ensure_pac_auth() {
  local idx
  idx="$(find_auth_index || true)"
  if [ -z "$idx" ]; then
    log "no pac auth profile for ${PAC_ENVIRONMENT_URL}; starting interactive sign-in..."
    pac auth create --url "$PAC_ENVIRONMENT_URL"
    idx="$(find_auth_index || true)"
  fi

  [ -n "$idx" ] || die "pac auth profile for ${PAC_ENVIRONMENT_URL} was not found after sign-in"
  pac auth select --index "$idx" >/dev/null
  ok "selected pac auth profile ${idx} for ${PAC_ENVIRONMENT_URL}"

  pac org who --environment "$PAC_ENVIRONMENT_URL" >/dev/null 2>&1 \
    || die "pac cannot access ${PAC_ENVIRONMENT_URL}; verify Copilot Studio/Power Platform licensing and permissions to edit agents and configure connections"
  ok "pac org access confirmed"
}

render_connector() {
  local api_def api_props host ns agent
  api_def="$REPO_ROOT/.run/connector/apiDefinition.json"
  api_props="$REPO_ROOT/.run/connector/apiProperties.json"
  host="$(sed_escape "$TUNNEL_HOST")"
  ns="$(sed_escape "$AGENT_NAMESPACE")"
  agent="$(sed_escape "$AGENT_NAME")"

  mkdir -p "$REPO_ROOT/.run/connector"
  cp "$REPO_ROOT/copilot/connector/apiDefinition.json" "$api_def"
  cp "$REPO_ROOT/copilot/connector/apiProperties.json" "$api_props"
  sed -e "s|__TUNNEL_HOST__|${host}|g" \
      -e "s|__A2A_NAMESPACE__|${ns}|g" \
      -e "s|__A2A_AGENT__|${agent}|g" \
      "$REPO_ROOT/copilot/connector/apiDefinition.json" > "$api_def"

  ok "rendered connector host=${TUNNEL_HOST} path=/api/a2a/${AGENT_NAMESPACE}/${AGENT_NAME}"
}

find_connector_id() {
  pac connector list --environment "$PAC_ENVIRONMENT_URL" 2>/dev/null \
    | awk -v display="$CONNECTOR_DISPLAY_NAME" 'index($0, display) > 0 { print $1; exit }'
}

upsert_connector() {
  local api_def api_props connector_id
  api_def="$REPO_ROOT/.run/connector/apiDefinition.json"
  api_props="$REPO_ROOT/.run/connector/apiProperties.json"
  connector_id="$(find_connector_id || true)"

  if [ -n "$connector_id" ]; then
    log "updating connector '${CONNECTOR_DISPLAY_NAME}' (${connector_id})..."
    pac connector update \
      --environment "$PAC_ENVIRONMENT_URL" \
      --connector-id "$connector_id" \
      --api-definition-file "$api_def" \
      --api-properties-file "$api_props" \
      --solution-unique-name "$COPILOT_SOLUTION_NAME"
  else
    log "creating connector '${CONNECTOR_DISPLAY_NAME}'..."
    pac connector create \
      --environment "$PAC_ENVIRONMENT_URL" \
      --api-definition-file "$api_def" \
      --api-properties-file "$api_props" \
      --solution-unique-name "$COPILOT_SOLUTION_NAME"
    connector_id="$(find_connector_id || true)"
  fi

  if [ -n "$connector_id" ]; then
    ok "connector ready: ${connector_id}"
  else
    warn "connector deployed, but pac connector list did not return an id for '${CONNECTOR_DISPLAY_NAME}'"
  fi
  # NOTE: pac connector has no delete command in pac 2.8.1; teardown should delete the solution.
}

# copilot_id() is provided by lib.sh (shared with 95-open-ui.sh); it matches the
# host agent by $COPILOT_AGENT_DISPLAY_NAME in $PAC_ENVIRONMENT_URL.

pack_and_import_copilot() {
  local workspace out_dir solution_zip instructions id agent_yml
  workspace="$REPO_ROOT/.run/copilot-agent"
  out_dir="$REPO_ROOT/.run/copilot-solution"
  instructions="$REPO_ROOT/copilot/agent/instructions.md"

  [ -f "$instructions" ] || die "missing host-agent instructions: ${instructions}"
  rm -rf "$workspace" "$out_dir"
  mkdir -p "$workspace" "$out_dir"

  # pac copilot init only creates a NEW agent; it errors if the schema name
  # already exists. Clone the deployed agent to update it idempotently, and init
  # only on first deploy. The two paths deploy differently (see below): a cloned
  # workspace is pushed with `pac copilot push`, while a fresh init workspace is
  # packed into a solution and imported.
  local mode
  id="$(copilot_id || true)"
  if [ -n "$id" ]; then
    mode="update"
    log "host agent '${COPILOT_AGENT_DISPLAY_NAME}' exists (${id}) — cloning to update"
    pac copilot clone \
      --bot "$id" \
      --output-dir "$workspace" \
      --environment "$PAC_ENVIRONMENT_URL"
  else
    mode="create"
    log "host agent '${COPILOT_AGENT_DISPLAY_NAME}' not found — initializing new workspace"
    # pac 2.8.1's --instructions parser breaks on newlines (it re-tokenizes the
    # value and chokes on the second line), so init with a single-line
    # placeholder; the real multi-line markdown is injected below.
    pac copilot init \
      --name "$COPILOT_AGENT_DISPLAY_NAME" \
      --publisher-prefix "$COPILOT_PUBLISHER_PREFIX" \
      --instructions "placeholder" \
      --schema-name "$COPILOT_AGENT_SCHEMA_NAME" \
      --project-dir "$workspace" \
      --environment "$PAC_ENVIRONMENT_URL"
  fi

  # init writes agent.mcs.yml at the workspace root; clone nests it in a folder
  # named after the agent's display name — locate it either way.
  agent_yml="$(find "$workspace" -maxdepth 2 -type f -name 'agent.mcs.yml' | head -1)"
  [ -n "$agent_yml" ] && [ -f "$agent_yml" ] || die "could not find agent.mcs.yml under ${workspace}"
  local agent_dir; agent_dir="$(dirname "$agent_yml")"
  awk -v f="$instructions" '
    skip {
      # consume the previous block-scalar body (indented or blank lines) so we
      # replace it instead of appending a duplicate copy on every re-deploy.
      if ($0 ~ /^[[:space:]]/ || $0 == "") next
      skip = 0
    }
    /^instructions:/ {
      print "instructions: |-"
      while ((getline line < f) > 0) print "  " line
      close(f)
      skip = 1
      next
    }
    { print }
  ' "$agent_yml" > "$agent_yml.tmp" && mv "$agent_yml.tmp" "$agent_yml"
  grep -q '^instructions: |-' "$agent_yml" || die "failed to inject instructions into ${agent_yml}"
  ok "injected host-agent instructions from ${instructions}"

  if [ "$mode" = "update" ]; then
    # A cloned workspace contains extra component dirs (workflows/, .mcs/) that
    # `pac copilot pack` rejects; push the workspace changes directly instead.
    pac copilot push --project-dir "$agent_dir"
    ok "host agent updated via push (${id})"
    return 0
  fi

  # First-deploy path: package the fresh workspace into a solution and import it.
  # NOTE: pac copilot pack help calls --output-path an output path, not --zipfile;
  # using a directory and discovering the produced .zip keeps this compatible.
  pac copilot pack \
    --publisher-prefix "$COPILOT_PUBLISHER_PREFIX" \
    --project-dir "$agent_dir" \
    --solution-name "$COPILOT_SOLUTION_NAME" \
    --output-path "$out_dir"

  solution_zip="$(find "$out_dir" -maxdepth 1 -type f -name '*.zip' | head -1)"
  [ -n "$solution_zip" ] || die "pac copilot pack did not produce a solution zip in ${out_dir}"

  pac solution import \
    --environment "$PAC_ENVIRONMENT_URL" \
    --path "$solution_zip" \
    --force-overwrite \
    --publish-changes
  ok "host agent deployed via solution ${COPILOT_SOLUTION_NAME}"
}

publish_copilot() {
  log "publishing host agent '${COPILOT_AGENT_DISPLAY_NAME}'..."
  # pac copilot publish --bot resolves a Copilot ID or schema name, but the
  # schema name is not discoverable via `pac copilot list` and does not resolve
  # reliably in pac 2.8.1, so publish by the deployed Copilot ID (GUID).
  local id
  id="$(copilot_id || true)"
  [ -n "$id" ] || die "could not find deployed Copilot ID for '${COPILOT_AGENT_DISPLAY_NAME}' (is it imported?)"

  # `pac copilot publish` submits the publish then polls its status for up to
  # 10 minutes. The publish keeps processing server-side even when that poll
  # times out ("Copilot status polling exceeded max wait time"), so retry: a
  # fresh attempt usually finds most of the work already done and completes
  # quickly. Only a polling timeout is retried; other errors fail immediately.
  local attempt out rc
  for attempt in 1 2 3; do
    set +e
    out="$(pac copilot publish --environment "$PAC_ENVIRONMENT_URL" --bot "$id" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out" >&2
    if [ "$rc" -eq 0 ]; then
      ok "host agent published (${id})"
      return 0
    fi
    if printf '%s' "$out" | grep -qi 'status polling exceeded max wait time'; then
      if [ "$attempt" -lt 3 ]; then
        warn "publish status polling timed out (attempt ${attempt}/3) — the publish is still processing server-side; retrying in 30s..."
        sleep 30
        continue
      fi
      warn "publish status polling timed out after ${attempt} attempts; the publish was submitted and is likely still completing server-side"
      warn "verify in the Maker portal (Copilot Studio → '${COPILOT_AGENT_DISPLAY_NAME}' → Publish); re-run 'make deploy' if it did not finish"
      die "host agent publish did not confirm within the allotted time"
    fi
    die "host agent publish failed (exit ${rc})"
  done
}

ensure_pac_auth

render_connector
pack_and_import_copilot
upsert_connector
publish_copilot

printf '%s\n' \
  "Summary:" \
  "  A2A endpoint: ${A2A_ENDPOINT}" \
  "  Host agent: ${COPILOT_AGENT_DISPLAY_NAME} (${COPILOT_AGENT_SCHEMA_NAME})" \
  "  Solution: ${COPILOT_SOLUTION_NAME}" \
  "  Next: run 'make demo' to open the portal + see the one-time A2A bind steps, then Publish in the portal"
ok "copilot-deploy complete"
