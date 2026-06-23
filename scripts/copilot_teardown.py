#!/usr/bin/env python3
"""Idempotent Copilot Studio teardown REST helpers (stdlib only).

Used by scripts/99-teardown.sh to remove the two resources `pac` cannot delete
itself: the environment-level PowerApps *connection* (pac connection delete is
broken in default environments) and the Dataverse custom *connector* (pac has no
connector delete in 2.8.1). Both reuse the MSAL tokens already cached by pac, so
there are no extra dependencies.

Usage:
    copilot_teardown.py connection
    copilot_teardown.py connector <connector-id>

Environment:
    PAC_ENVIRONMENT_URL          Dataverse org URL (required for `connector`;
                                 used to derive the environment name fallback)
    CONNECTOR_DISPLAY_NAME       custom connector display name (`connection`)
    COPILOT_CONNECTOR_API_NAME   optional connector API name hint (`connection`)
    PAC_ENVIRONMENT_NAME /
    POWERAPPS_ENVIRONMENT_NAME   optional Power Platform environment name

Exit codes: 0 on success or "already absent"; 1 on a hard failure (no usable
token, missing environment name, unexpected HTTP error) so the caller can warn
and print a manual-cleanup hint.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CACHE = Path.home() / ".local/share/Microsoft/PowerAppsCli/tokencache_msalv3.dat"
CLIENT_ID = "9cee029c-6210-4654-90bb-17e6e9d36617"
POWERAPPS_AUDIENCES = ("https://service.powerapps.com/", "https://api.powerapps.com/")
POWERAPPS_API_ROOT = "https://api.powerapps.com"
POWERAPPS_API_VERSION = "2016-11-01"


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


# --- shared MSAL token-cache access ---------------------------------------
def load_cache():
    if not CACHE.exists():
        fail(f"pac/MSAL token cache not found: {CACHE}")
    with CACHE.open(encoding="utf-8") as f:
        return json.load(f)


def values(cache, section):
    data = cache.get(section, {})
    return list(data.values()) if isinstance(data, dict) else []


def tenant_from_cache(cache):
    for section in ("Account", "RefreshToken"):
        for entry in values(cache, section):
            realm = entry.get("realm") or ""
            if realm:
                return realm
            home = entry.get("home_account_id") or ""
            if "." in home:
                return home.split(".", 1)[1]
    return ""


def refresh(cache, audience, tenant):
    if not tenant:
        return ""
    scope = audience.rstrip("/") + "/.default offline_access openid profile"
    url = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"
    for rt in values(cache, "RefreshToken"):
        secret = rt.get("secret") or rt.get("refresh_token") or ""
        if not secret:
            continue
        data = urllib.parse.urlencode({
            "client_id": CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": secret,
            "scope": scope,
        }).encode()
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=30) as resp:
                token = json.load(resp).get("access_token") or ""
            if token:
                return token
        except Exception:
            continue
    return ""


def get_token(cache, audience):
    needle = audience.lower().rstrip("/")
    now = int(time.time())
    for at in values(cache, "AccessToken"):
        target = (at.get("target") or "").lower()
        if needle in target and int(at.get("expires_on") or "0") > now + 60:
            return at.get("secret") or ""
    return refresh(cache, audience, tenant_from_cache(cache))


def token_for(cache, *audiences):
    for audience in audiences:
        token = get_token(cache, audience)
        if token:
            return token
    return ""


# --- HTTP helpers ----------------------------------------------------------
def request(method, url, token, extra_headers=None):
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=45) as resp:
        if resp.status == 204:
            return {}
        raw = resp.read()
        return json.loads(raw.decode() or "{}") if raw else {}


def request_list(url, token):
    # A 404 here means the API/connector is already gone — treat as empty.
    try:
        return request("GET", url, token).get("value", [])
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise


def item_name(item):
    return (item.get("name") or "").rsplit("/", 1)[-1]


def item_display(item):
    props = item.get("properties") or {}
    return props.get("displayName") or props.get("connectionDisplayName") or item.get("displayName") or ""


# --- subcommands -----------------------------------------------------------
def delete_connection(cache):
    display = os.environ.get("CONNECTOR_DISPLAY_NAME", "")
    api_name = os.environ.get("COPILOT_CONNECTOR_API_NAME", "")

    token = token_for(cache, *POWERAPPS_AUDIENCES)
    if not token:
        fail("no usable PowerApps access token found in pac/MSAL cache")

    tenant = tenant_from_cache(cache)
    env_name = (
        os.environ.get("PAC_ENVIRONMENT_NAME")
        or os.environ.get("POWERAPPS_ENVIRONMENT_NAME")
        or (f"Default-{tenant}" if tenant else "")
    )
    if not env_name:
        fail("could not determine Power Platform environment name")
    flt = urllib.parse.quote(f"environment eq '{env_name}'", safe="")

    if not api_name:
        apis_url = f"{POWERAPPS_API_ROOT}/providers/Microsoft.PowerApps/apis?api-version={POWERAPPS_API_VERSION}&$filter={flt}"
        for api in request_list(apis_url, token):
            if item_display(api) == display:
                api_name = item_name(api)
                break
    if not api_name:
        print(f"connector '{display}' not found — no PowerApps connection to delete")
        return

    encoded_api = urllib.parse.quote(api_name, safe="")
    conn_url = f"{POWERAPPS_API_ROOT}/providers/Microsoft.PowerApps/apis/{encoded_api}/connections?api-version={POWERAPPS_API_VERSION}&$filter={flt}"
    deleted = 0
    for conn in request_list(conn_url, token):
        conn_id = item_name(conn)
        if not conn_id:
            continue
        encoded_conn = urllib.parse.quote(conn_id, safe="")
        delete_url = f"{POWERAPPS_API_ROOT}/providers/Microsoft.PowerApps/apis/{encoded_api}/connections/{encoded_conn}?api-version={POWERAPPS_API_VERSION}&$filter={flt}"
        try:
            request("DELETE", delete_url, token)
            deleted += 1
            print(f"deleted PowerApps connection {conn_id} for API {api_name}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue
            raise
    if deleted == 0:
        print(f"no PowerApps connections found for API {api_name} in {env_name}")


def delete_connector(cache, connector_id):
    org_url = os.environ.get("PAC_ENVIRONMENT_URL", "").rstrip("/")
    if not org_url:
        fail("PAC_ENVIRONMENT_URL not set")
    if not connector_id:
        fail("connector id required")

    token = token_for(cache, org_url)
    if not token:
        fail("no usable Dataverse access token found in pac/MSAL cache")

    url = f"{org_url}/api/data/v9.2/connectors({connector_id})"
    headers = {"OData-MaxVersion": "4.0", "OData-Version": "4.0"}
    try:
        request("DELETE", url, token, headers)
        print("Dataverse connector deleted")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("Dataverse connector already absent")
        else:
            raise


def main(argv):
    if not argv:
        fail("usage: copilot_teardown.py {connection|connector <id>}")
    mode = argv[0]
    cache = load_cache()
    if mode == "connection":
        delete_connection(cache)
    elif mode == "connector":
        delete_connector(cache, argv[1] if len(argv) > 1 else "")
    else:
        fail(f"unknown mode: {mode}")


if __name__ == "__main__":
    main(sys.argv[1:])
