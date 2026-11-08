#!/usr/bin/env bash
# Diagnostics for the paperclip-agent devcontainer Feature.
#
# Human-readable checks go to stderr; the environment manifest goes to stdout.
# With --json, stdout is one document:
#
#   {
#     "ok": bool,
#     "container_id": "...", "project_name": "...",
#     "slug": "...", "network_alias": "...",
#     "checks": [ { "id", "ok", "detail" } ],
#     "manifest": { ... }
#   }
#
# Hard failures: sshd, ssh_host_keys, claude, authorized_keys, mcp_config,
# manifest, and workspace.
# Together Link presence/auth, MCP server reachability, Paperclip API DNS and
# HTTP reachability are warnings.

set -u

JSON_MODE=0
case "${1:-}" in
  --json) JSON_MODE=1 ;;
  "") ;;
  *)
    printf 'usage: paperclip-agent-doctor [--json]\n' >&2
    exit 2
    ;;
esac

SSH_PORT=2222
SHARED_DIR="/opt/paperclip/shared"
AUTHORIZED_KEYS="${SHARED_DIR}/authorized_keys"
MCP_CONFIG="${SHARED_DIR}/mcp-extra.json"
MANIFEST="/opt/paperclip/environment.json"
NETWORK_NAME="paperclip-net"
WORKSPACE_FILE="/opt/paperclip/remote-workspace"
WORKSPACE_OPTION_FILE="/etc/paperclip-agent/remote-workspace"

# Print the workspace the entrypoint resolved at container start. Prefer the
# plain-text copy it writes next to the manifest, then the manifest field, then
# the persisted option. Never derive the path from this script's own $PWD: an
# SSH command runs in the user's home directory, not the workspace.
resolve_workspace() {
  local path=""
  if [ -r "$WORKSPACE_FILE" ]; then
    IFS= read -r path <"$WORKSPACE_FILE" || true
  fi
  if [ -z "$path" ] && [ -f "$MANIFEST" ]; then
    if command -v node >/dev/null 2>&1; then
      path="$(node -e '
        const fs = require("fs");
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (typeof j.remoteWorkspacePath === "string") process.stdout.write(j.remoteWorkspacePath);
      ' "$MANIFEST" 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
      path="$(python3 -c '
import json, sys
j = json.load(open(sys.argv[1]))
v = j.get("remoteWorkspacePath")
if isinstance(v, str):
    sys.stdout.write(v)
' "$MANIFEST" 2>/dev/null || true)"
    else
      path="$(sed -n 's/.*"remoteWorkspacePath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" 2>/dev/null | head -n 1)"
    fi
  fi
  if [ -z "$path" ] && [ -r "$WORKSPACE_OPTION_FILE" ]; then
    path="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$WORKSPACE_OPTION_FILE" 2>/dev/null | head -n 1)"
  fi

  [ -n "$path" ] || path="/workspace"
  printf '%s\n' "$path"
}

# Paperclip's SSH runner sources /etc/profile before each command. Source the
# same file here so a manual `ssh target paperclip-agent-doctor` (a
# non-interactive, non-login shell) sees the same PATH and paperclip.env.
# shellcheck disable=SC1091
[ -r /etc/profile.d/paperclip-agent.sh ] && . /etc/profile.d/paperclip-agent.sh

WORKSPACE="$(resolve_workspace)"

hard_failures=0
json_checks=()

json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

add_check() {
  local id="$1" ok="$2" detail="$3" hard="${4:-0}"
  if [ "$ok" = "true" ]; then
    printf '[ ok ] %s: %s\n' "$id" "$detail" >&2
  elif [ "$hard" = "1" ]; then
    printf '[FAIL] %s: %s\n' "$id" "$detail" >&2
    hard_failures=$((hard_failures + 1))
  else
    printf '[warn] %s: %s\n' "$id" "$detail" >&2
  fi

  local entry="{\"id\":$(json_str "$id"),\"ok\":$ok,\"detail\":$(json_str "$detail")"
  if [ "$ok" = "false" ] && [ "$hard" = "0" ]; then
    entry="${entry},\"warning\":true"
  fi
  entry="${entry}}"
  json_checks+=("$entry")
}

# Parse the shared MCP config with node or python3 (never jq). Prints the
# server count on the first line, then one "name<TAB>url" line per HTTP server.
# Returns 2 when no parser is available.
mcp_parse() {
  local file="$1"
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const servers = j.mcpServers || {};
      const entries = Object.entries(servers);
      process.stdout.write(String(entries.length) + "\n");
      for (const [name, cfg] of entries) {
        if (cfg && typeof cfg.url === "string" && cfg.url) {
          process.stdout.write(name + "\t" + cfg.url + "\n");
        }
      }
    ' "$file"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
j = json.load(open(sys.argv[1]))
servers = j.get("mcpServers", {}) or {}
print(len(servers))
for name, cfg in servers.items():
    if isinstance(cfg, dict) and isinstance(cfg.get("url"), str) and cfg["url"]:
        print(f"{name}\t{cfg['url']}")
' "$file"
  else
    return 2
  fi
}

# --- sshd host keys ----------------------------------------------------------

host_key_count=0
for host_key in /etc/ssh/ssh_host_*_key; do
  [ -f "$host_key" ] && host_key_count=$((host_key_count + 1))
done
if [ "$host_key_count" -gt 0 ]; then
  add_check ssh_host_keys true "${host_key_count} key(s) in /etc/ssh" 1
else
  add_check ssh_host_keys false "no /etc/ssh/ssh_host_*_key; run 'sudo ssh-keygen -A' (sshd exits with 'no hostkeys available')" 1
fi

# --- sshd --------------------------------------------------------------------

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | awk -v p=":${SSH_PORT}" '$4 ~ p "$" { found = 1 } END { exit !found }'; then
    add_check sshd true "listening on ${SSH_PORT}" 1
  else
    add_check sshd false "no listener on port ${SSH_PORT}" 1
  fi
elif pgrep -x sshd >/dev/null 2>&1; then
  add_check sshd true "sshd process running (port not verified)" 0
else
  add_check sshd false "sshd is not running" 1
fi

# --- agent CLIs --------------------------------------------------------------

if command -v claude >/dev/null 2>&1; then
  if claude_version="$(claude --version 2>&1)"; then
    add_check claude true "$claude_version" 1
  else
    add_check claude false "claude --version failed: ${claude_version}" 1
  fi
else
  add_check claude false "not on PATH; source /etc/profile or check /etc/profile.d/paperclip-agent.sh" 1
fi

if command -v togetherlink >/dev/null 2>&1; then
  if tl_version="$(togetherlink --version 2>&1)"; then
    add_check togetherlink true "$tl_version" 0
  else
    add_check togetherlink false "togetherlink --version failed: ${tl_version}" 0
  fi
else
  add_check togetherlink false "not on PATH; source /etc/profile or check /etc/profile.d/paperclip-agent.sh" 0
fi

# --- Together auth (warning) -------------------------------------------------

together_config="${HOME:-}/.togetherlink/config.json"
if [ -z "${HOME:-}" ] || [ ! -f "$together_config" ]; then
  add_check together_auth false "config.json absent; run 'togetherlink configure' or mount ~/.togetherlink via agent-home" 0
elif ! command -v togetherlink >/dev/null 2>&1; then
  add_check together_auth false "config.json present but togetherlink is not on PATH" 0
else
  models_cmd="togetherlink models"
  command -v timeout >/dev/null 2>&1 && models_cmd="timeout 20 togetherlink models"
  if models_output="$($models_cmd 2>&1)"; then
    add_check together_auth true "config.json present; models listed" 0
  else
    models_output="${models_output//$'\n'/ }"
    add_check together_auth false "config.json present; 'togetherlink models' failed: ${models_output:0:200}" 0
  fi
fi

# --- shared files ------------------------------------------------------------

if [ -s "$AUTHORIZED_KEYS" ]; then
  add_check authorized_keys true "present: ${AUTHORIZED_KEYS}" 1
else
  add_check authorized_keys false "missing or empty: ${AUTHORIZED_KEYS}" 1
fi

mcp_tmp="$(mktemp 2>/dev/null || printf '/tmp/paperclip-agent-mcp.%s' "$$")"
mcp_parsed=0
if [ ! -f "$MCP_CONFIG" ]; then
  add_check mcp_config false "missing: ${MCP_CONFIG}" 1
else
  mcp_output="$(mcp_parse "$MCP_CONFIG" 2>/dev/null)"
  parse_status=$?
  if [ "$parse_status" -eq 0 ]; then
    printf '%s\n' "$mcp_output" >"$mcp_tmp"
    mcp_parsed=1
    mcp_server_count="$(head -n 1 "$mcp_tmp" 2>/dev/null || echo 0)"
    add_check mcp_config true "${mcp_server_count} server(s) in ${MCP_CONFIG}" 1
  elif [ "$parse_status" -eq 2 ]; then
    add_check mcp_config false "no node or python3 available to parse ${MCP_CONFIG}" 1
  else
    add_check mcp_config false "not valid JSON: ${MCP_CONFIG}" 1
  fi
fi

# --- MCP server reachability (warning) ---------------------------------------

if [ "$mcp_parsed" -eq 1 ]; then
  if ! command -v curl >/dev/null 2>&1; then
    add_check mcp_servers false "curl is not available" 0
  else
    total=0
    reachable=0
    failed=""
    while IFS="$(printf '\t')" read -r name url; do
      [ -n "$url" ] || continue
      total=$((total + 1))
      code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
      if [ -n "$code" ] && [ "$code" != "000" ]; then
        reachable=$((reachable + 1))
      else
        failed="${failed}${failed:+, }${name}"
      fi
    done < <(tail -n +2 "$mcp_tmp")
    if [ "$total" -eq 0 ]; then
      add_check mcp_servers true "no HTTP servers to probe" 0
    elif [ "$reachable" -eq "$total" ]; then
      add_check mcp_servers true "${reachable}/${total} reachable" 0
    else
      add_check mcp_servers false "${reachable}/${total} reachable (failed: ${failed})" 0
    fi
  fi
else
  add_check mcp_servers false "skipped; MCP config did not parse" 0
fi
rm -f "$mcp_tmp"

# --- workspace ---------------------------------------------------------------

if [ -d "$WORKSPACE" ]; then
  add_check workspace true "${WORKSPACE}" 1
else
  add_check workspace false "missing: ${WORKSPACE}; set remoteWorkspacePath or make the container working directory the workspace" 1
fi

# --- Paperclip API DNS and HTTP (warnings) -----------------------------------

api_url="${PAPERCLIP_API_URL:-}"
if [ -z "$api_url" ]; then
  add_check paperclip_api_dns false "PAPERCLIP_API_URL unset (add ${SHARED_DIR}/paperclip.env)" 0
else
  api_host="${api_url#*://}"
  api_host="${api_host%%/*}"
  api_host="${api_host%%:*}"
  if [ -n "$api_host" ] && getent hosts "$api_host" >/dev/null 2>&1; then
    add_check paperclip_api_dns true "${api_host} resolves" 0
  else
    add_check paperclip_api_dns false "${api_host:-<unknown>} does not resolve; check ${NETWORK_NAME} and the paperclip-control alias" 0
  fi
fi

if [ -z "$api_url" ]; then
  add_check paperclip_api false "PAPERCLIP_API_URL unset" 0
elif ! command -v curl >/dev/null 2>&1; then
  add_check paperclip_api false "curl is not available" 0
else
  code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "${api_url%/}/api/health" 2>/dev/null || true)"
  case "$code" in
    200 | 401 | 403) add_check paperclip_api true "HTTP ${code}" 0 ;;
    *) add_check paperclip_api false "unreachable (HTTP ${code:-000})" 0 ;;
  esac
fi

# --- manifest presence and writability ---------------------------------------

# The entrypoint rewrites the manifest on every start. On a Compose target it
# runs as the remote user, so a root-owned /opt/paperclip needs sudo.
manifest_dir="$(dirname "$MANIFEST")"
manifest_writable=0
if [ -f "$MANIFEST" ]; then
  # The entrypoint overwrites the existing file, so its own mode decides.
  [ -w "$MANIFEST" ] && manifest_writable=1
elif [ -w "$manifest_dir" ]; then
  manifest_writable=1
fi
if [ "$manifest_writable" -eq 0 ] &&
  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  manifest_writable=1
fi

if [ -f "$MANIFEST" ] && [ -r "$MANIFEST" ] && [ "$manifest_writable" -eq 1 ]; then
  add_check manifest true "present and writable: ${MANIFEST}" 1
elif [ -f "$MANIFEST" ] && [ -r "$MANIFEST" ]; then
  add_check manifest false "${MANIFEST} exists but is not writable by $(id -un); the next start cannot update it. Rebuild the Feature so ${manifest_dir} is owned by the remote user, or allow passwordless sudo" 1
elif [ -f "$MANIFEST" ]; then
  add_check manifest false "present but unreadable: ${MANIFEST}" 1
elif [ "$manifest_writable" -eq 1 ]; then
  add_check manifest false "missing: ${MANIFEST}; ${manifest_dir} is writable, so the entrypoint did not run or failed — check 'docker logs' and restart the container" 1
else
  add_check manifest false "missing: ${MANIFEST}, and ${manifest_dir} is not writable by $(id -un). Rebuild the Feature so the directory is owned by the remote user, or allow passwordless sudo" 1
fi

# --- manifest fields ---------------------------------------------------------

manifest_json="null"
container_id="null"
project_name="null"
project_slug="null"
network_alias="null"

if [ -f "$MANIFEST" ]; then
  if command -v node >/dev/null 2>&1; then
    if manifest_fields="$(node -e '
      const fs = require("fs");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const v = (x) => JSON.stringify(x === undefined ? null : x);
      console.log(v(j.containerId));
      console.log(v(j.projectName));
      console.log(v(j.slug));
      console.log(v(j.network && j.network.alias));
    ' "$MANIFEST" 2>/dev/null)"; then
      manifest_json="$(cat "$MANIFEST")"
      container_id="$(printf '%s\n' "$manifest_fields" | sed -n '1p')"
      project_name="$(printf '%s\n' "$manifest_fields" | sed -n '2p')"
      project_slug="$(printf '%s\n' "$manifest_fields" | sed -n '3p')"
      network_alias="$(printf '%s\n' "$manifest_fields" | sed -n '4p')"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if manifest_fields="$(python3 -c '
import json, sys
j = json.load(open(sys.argv[1]))
print(json.dumps(j.get("containerId")))
print(json.dumps(j.get("projectName")))
print(json.dumps(j.get("slug")))
print(json.dumps((j.get("network") or {}).get("alias")))
' "$MANIFEST" 2>/dev/null)"; then
      manifest_json="$(cat "$MANIFEST")"
      container_id="$(printf '%s\n' "$manifest_fields" | sed -n '1p')"
      project_name="$(printf '%s\n' "$manifest_fields" | sed -n '2p')"
      project_slug="$(printf '%s\n' "$manifest_fields" | sed -n '3p')"
      network_alias="$(printf '%s\n' "$manifest_fields" | sed -n '4p')"
    fi
  else
    manifest_json="$(cat "$MANIFEST")"
  fi
fi

# --- output ------------------------------------------------------------------

overall="true"
[ "$hard_failures" -eq 0 ] || overall="false"

if [ "$JSON_MODE" -eq 1 ]; then
  checks_json=""
  if [ "${#json_checks[@]}" -gt 0 ]; then
    checks_json="$(IFS=,; printf '%s' "${json_checks[*]}")"
  fi
  printf '{"ok":%s,"container_id":%s,"project_name":%s,"slug":%s,"network_alias":%s,"checks":[%s],"manifest":%s}\n' \
    "$overall" "$container_id" "$project_name" "$project_slug" "$network_alias" "$checks_json" "$manifest_json"
else
  [ "$manifest_json" != "null" ] && printf '%s\n' "$manifest_json"
fi

if [ "$hard_failures" -ne 0 ]; then
  printf 'paperclip-agent-doctor: %d hard check(s) failed\n' "$hard_failures" >&2
  exit 1
fi
exit 0
