# Paperclip Agent Host

Prepares a dev container as the **target** of a Paperclip SSH environment on a shared Docker network. Paperclip reaches each target by a network alias on the same internal port `2222`; no host port is published.

The Paperclip server (the control plane) runs elsewhere. This Feature never installs, configures, or calls Paperclip. It makes the container connectable, reads a mandatory host config directory, and writes a minimal manifest the host-side enrollment script consumes.

## What it does

- Installs `openssh-server` and writes a key-only config on port `2222`: no passwords, no root login, no `PermitUserEnvironment`, only the remote user allowed.
- Copies `/opt/paperclip/shared/authorized_keys` into the remote user's `~/.ssh` at every start.
- Adds `/etc/profile.d/paperclip-agent.sh`, the contract that makes `claude` and `togetherlink` resolvable when Paperclip sources `/etc/profile` for a non-interactive SSH command.
- Writes `/opt/paperclip/environment.json` at start with the container ID, derived project name/slug, and the network alias.
- Installs `paperclip-agent-doctor` (human output or `--json`).
- Depends on [`claude-code`](../claude-code) and [`together-link`](../together-link), so those Features install even if the target `devcontainer.json` does not list them.

## Why `/opt/paperclip`

The container is disposable and the control plane lives outside it, so the Feature keeps its outputs at stable, readable paths:

| Path | Purpose |
| --- | --- |
| `/opt/paperclip/shared` | Mandatory host `~/.paperclip` fleet config (fixed bind mount) |
| `/opt/paperclip/environment.json` | Minimal manifest written at container start |
| `/etc/paperclip-agent/user` | Resolved remote username (`0644`) |
| `/etc/paperclip-agent/project-name` | Optional `projectName` override (`0644`) |
| `/etc/profile.d/paperclip-agent.sh` | `PATH`, `PAPERCLIP_AGENT_*`, and `paperclip.env` for SSH sessions |
| `/usr/local/share/paperclip-agent/entrypoint.sh` | Start-time key copy, manifest, host keys, sshd |
| `/usr/local/bin/paperclip-agent-doctor` | Diagnostics + manifest |

## Usage

The host `~/.paperclip` directory is mandatory. Create it before starting the container:

```bash
mkdir -p ~/.paperclip/projects
```

An image-based target joins the network with `runArgs`:

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": {
    "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {},
    "ghcr.io/aj-foster/devcontainer-features/paperclip-agent:1": {
      "projectName": "project-foo"
    }
  },
  "runArgs": ["--network=paperclip-net", "--network-alias=project-foo"]
}
```

A Compose target joins it as an external network (see [Networking](#networking)). The `runArgs` path assumes `paperclip-net` already exists; the Paperclip Compose file creates it, or run `docker network create paperclip-net` first. The zero-config path is the enrollment script's `docker network connect --alias <slug> paperclip-net <containerId>`.

`agent-home` is strongly recommended. It bind-mounts the host's `~/.togetherlink`, so Together Link auth configured on the host is available to the agent over SSH. Without it, run `togetherlink configure` inside the target once.

## Requirements and assumptions

- Debian/Ubuntu image with `apt-get` and `remoteUser: vscode`. The install fails clearly elsewhere.
- The remote user must already exist. `claude-code` and `together-link` install as that user, and Paperclip connects as that user.
- The Feature declares `claude-code` and `together-link` as `dependsOn`. If your devcontainer CLI ignores `dependsOn`, add both Features explicitly and rebuild.
- **The host `~/.paperclip` directory must exist before the container starts.** It is a bind-mount source, exactly like the paths `agent-home` requires.
- The Paperclip container and every target share the user-defined network `paperclip-net`.
- The Paperclip container is reachable from targets as `paperclip-control:3100`.
- Every target uses `/workspace`, sshd on `2222`, and the project slug as its network alias.
- The host-side enrollment script has Docker access and can run `docker network connect`.
- Published-port targets on remote Docker hosts and host-key pinning are out of scope for this iteration.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `projectName` | `""` | Optional human-friendly project name. Empty derives it from the workspace (git remote, package metadata, folder name, then hostname). |

## Shared configuration directory

The host's `~/.paperclip` is the source of truth for fleet-wide, non-secret configuration. It is mounted at `/opt/paperclip/shared` in every target and is **mandatory**.

> **This is not the Paperclip container's `~/.paperclip`.** The Paperclip server's own state lives in its `paperclip-data` volume. The directory mounted here is a plain host directory the operator creates.

The mount is a bind mount. The devcontainer Feature schema used by this repository accepts the object form but not `readonly`, so the mount is read-write at the Docker level. Treat it as read-only: the host is the only writer, files are host-owned `0644`, and targets run as the non-root remote user, which cannot modify them. Write files atomically on the host (temp file + `mv`).

Required files:

```
~/.paperclip/authorized_keys
~/.paperclip/mcp-extra.json
~/.paperclip/paperclip.env
~/.paperclip/paperclip-secrets.json
~/.paperclip/agent-template.json
~/.paperclip/AGENTS.md
~/.paperclip/first-task.json
~/.paperclip/projects/<slug>.json
```

`authorized_keys` holds the public keys Paperclip uses to connect. `mcp-extra.json` is the MCP config the agent loads. `paperclip.env` holds non-secret settings:

```sh
PAPERCLIP_API_URL=http://paperclip-control:3100
PAPERCLIP_COMPANY_ID=<company-id>
```

`paperclip-secrets.json` holds secret **IDs**, never values:

```json
{
  "sshPrivateKey": "<secret-id>",
  "togetherApiKey": "<secret-id>"
}
```

`agent-template.json` is the common agent config. Note the MCP path points directly at the shared file:

```json
{
  "role": "engineer",
  "title": "Project Agent",
  "capabilities": "Works in {{projectName}}; runs Claude Code on Together AI through Together Link's gateway.",
  "adapterType": "claude_local",
  "adapterConfig": {
    "engine": "cli",
    "cwd": "{{remoteWorkspacePath}}",
    "model": "auto",
    "env": {
      "ANTHROPIC_BASE_URL": "https://gateway.togetherlink.dev",
      "ANTHROPIC_API_KEY": { "type": "secret_ref", "secretId": "{{togetherApiKey}}", "version": "latest" },
      "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "0"
    },
    "timeoutSec": 600,
    "graceSec": 20,
    "maxTurnsPerRun": 300,
    "dangerouslySkipPermissions": false,
    "extraArgs": [
      "--allowedTools",
      "Read,Write,Edit,Bash,Glob,Grep,WebFetch,WebSearch,TodoWrite,Task,NotebookEdit,Skill,mcp__github__*,mcp__linear__*,mcp__notion__*,mcp__sentry__*,mcp__granola__*",
      "--mcp-config",
      "/opt/paperclip/shared/mcp-extra.json"
    ]
  }
}
```

`projects/<slug>.json` overrides the template per project:

```json
{
  "agentName": "Project Foo Agent",
  "role": "engineer",
  "title": "Project Foo Engineer",
  "capabilities": "Owns {{projectName}}.",
  "instructionsFile": "AGENTS.md"
}
```

`AGENTS.md` is optional default instructions with `{{projectName}}` and `{{remoteWorkspacePath}}` placeholders. `first-task.json` is an optional first issue:

```json
{
  "title": "Verify runtime and MCP tools",
  "description": "Confirm you are running on the Together gateway, then call mcp__github__get_me and mcp__linear__list_teams and report the results in this issue."
}
```

**Security:** no SSH private key, Paperclip token, or Together API key goes in this directory. Secret IDs and the company ID are fine.

## Project name and slug

The start script derives the project name in this order, using the first non-empty value:

1. the persisted `projectName` option (`/etc/paperclip-agent/project-name`);
2. if `/workspace` is a git work tree, the `origin` basename with a trailing `.git` stripped;
3. if `/workspace` is **not** a git work tree, its immediate child repositories:
   - one child uses its `origin` basename (or its directory name when it has no origin);
   - multiple children use their sorted directory names joined with `-` (for example, `api-docs-web`).
   Only immediate children are scanned, `node_modules` is ignored, and a top-level repo with no `origin` falls through to the steps below rather than guessing from children;
4. the `name` field in `/workspace/package.json`, or `project.name` in `/workspace/pyproject.toml`, or `package.name` in `/workspace/Cargo.toml`;
5. the basename of `/workspace`;
6. `$HOSTNAME`.

The slug is the name lowercased with runs of non-alphanumerics collapsed to `-`, leading/trailing hyphens trimmed, and capped at 63 characters because it is a Docker network alias. The slug is the network alias and the enrollment upsert key. Set `projectName` explicitly for nested or very large multi-repo layouts, or when truncation would collide.

## sshd and authorized keys

sshd is always installed and started on `2222`. The drop-in is key-only:

```
Port 2222
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 20
AllowUsers <user>
AuthorizedKeysFile .ssh/authorized_keys
UsePAM yes
PermitUserEnvironment no
```

At every start, the entrypoint copies `/opt/paperclip/shared/authorized_keys` into `~/.ssh/authorized_keys` (mode `0600`, user-owned). If the shared file is missing, it logs a warning and key auth fails. Rotating the shared file takes effect on the next start.

The Feature uses the image's default host keys, generating them with `ssh-keygen -A` if missing. There is no state volume and no pinned host key; the control plane uses `strictHostKeyChecking: false` on the local network.

## PATH and MCP config

`/etc/profile.d/paperclip-agent.sh` prepends the detected Claude Code, Node.js, and Together Link directories and sources the shared env:

```sh
export PATH="/opt/claude-code/bin:/opt/together-link/bin:${HOME}/.bun/bin:<detected-claude-dir>:<detected-node-dir>:$PATH"
export PAPERCLIP_AGENT_MCP_CONFIG="/opt/paperclip/shared/mcp-extra.json"
export PAPERCLIP_AGENT_REMOTE_WORKSPACE="/workspace"
if [ -f /opt/paperclip/shared/paperclip.env ]; then
  set -a
  . /opt/paperclip/shared/paperclip.env
  set +a
fi
```

There is no `/opt/paperclip/bin/claude` wrapper and no baked MCP default. Paperclip's SSH runner sources `/etc/profile`, so the profile.d PATH is sufficient for agent runs. A non-login `ssh host claude` may need `. /etc/profile` first. The agent template points `--mcp-config` directly at `/opt/paperclip/shared/mcp-extra.json`; the Feature only checks that the file exists.

## Networking

The Paperclip project's Compose file defines the network with a fixed name and a stable control-plane alias:

```yaml
services:
  app:
    networks:
      paperclip-net:
        aliases: [paperclip-control]

networks:
  paperclip-net:
    name: paperclip-net
```

The explicit `name:` matters; without it Compose prefixes the network with the project name.

A target project that uses Compose joins it as an external network with the slug alias:

```yaml
services:
  app:
    networks:
      paperclip-net:
        aliases: [project-foo]

networks:
  paperclip-net:
    external: true
    name: paperclip-net
```

An image-based target uses `runArgs`:

```json
"runArgs": ["--network=paperclip-net", "--network-alias=project-foo"]
```

The zero-config path is the enrollment script's `docker network connect --alias <slug> paperclip-net <containerId>`.

The Paperclip control plane needs: the `paperclip-control` alias, a server bind on `0.0.0.0`, `paperclip-control` allowed as a hostname, and in `~/.paperclip/paperclip.env`:

```sh
PAPERCLIP_API_URL=http://paperclip-control:3100
PAPERCLIP_COMPANY_ID=<company-id>
```

Do not publish `3100` to the host for this pattern. Note the trust boundary: every container on `paperclip-net` can reach every other container's ports; keep the network dedicated to Paperclip and targets.

Remote Docker hosts are out of scope for this iteration. Use a VPN/Tailscale or extend the Feature if you need published-port targets.

## Doctor

`paperclip-agent-doctor` keeps its human-readable output (checks on stderr, manifest on stdout) and `--json`. The checks are:

- `sshd` — listening on `2222`.
- `claude`, `togetherlink` — version commands.
- `together_auth` — `~/.togetherlink/config.json` exists and `togetherlink models` exits 0 (warning).
- `authorized_keys` — the shared file exists and is non-empty (hard).
- `mcp_config` — the shared MCP config exists and parses (hard).
- `mcp_servers` — probe every URL with `curl`; any HTTP response counts as reachable, `000` fails (warning).
- `workspace` — `/workspace` exists (hard).
- `paperclip_api_dns` — resolve the host portion of `PAPERCLIP_API_URL` (warning).
- `paperclip_api` — HTTP probe `$PAPERCLIP_API_URL/api/health`; accept `200`, `401`, `403` (warning).

The JSON also reports `container_id`, `project_name`, `slug`, and `network_alias`:

```json
{
  "ok": true,
  "container_id": "2dc59b19afa2",
  "project_name": "project-foo",
  "slug": "project-foo",
  "network_alias": "project-foo",
  "checks": [ { "id": "sshd", "ok": true, "detail": "listening on 2222" } ],
  "manifest": { }
}
```

Hard failures are `sshd`, `claude`, `authorized_keys`, `mcp_config`, and `workspace`.

## Host-side enrollment

There is no target-side enrollment command. The host-side `enroll.sh` is the only enrollment path. It runs on the host (Docker access) or in the Paperclip container with the Docker socket. Auth is `paperclipai` board context or `PAPERCLIP_API_TOKEN`.

`HOST` is the address reachable from wherever the script runs for the initial SSH read (on a Linux Docker host, the container IP works; from the Paperclip container, an existing alias or the container IP). `CONTAINER` is the Docker container name/ID used for the network attach.

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${HOST:?set HOST (target address for the initial SSH read)}"
: "${CONTAINER:?set CONTAINER (Docker container name/id)}"
: "${PAPERCLIP_CONTAINER:?set PAPERCLIP_CONTAINER (Paperclip control container)}"
NETWORK="${NETWORK:-paperclip-net}"
PAPERCLIP_DIR="${PAPERCLIP_DIR:-$HOME/.paperclip}"
SSH_USER="${SSH_USER:-vscode}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/paperclip_agents}"

# Non-secret fleet settings.
if [ -f "$PAPERCLIP_DIR/paperclip.env" ]; then
  set -a
  . "$PAPERCLIP_DIR/paperclip.env"
  set +a
fi
: "${PAPERCLIP_API_URL:?set PAPERCLIP_API_URL (or add it to paperclip.env)}"
: "${PAPERCLIP_API_TOKEN:?set PAPERCLIP_API_TOKEN (or adapt to paperclipai board context)}"
COMPANY="${PAPERCLIP_COMPANY_ID:?set PAPERCLIP_COMPANY_ID}"
API="${PAPERCLIP_API_URL%/}"

api() {
  curl -sS -f -H "Authorization: Bearer ${PAPERCLIP_API_TOKEN}" \
    -H 'Content-Type: application/json' "$@"
}

items() {
  jq 'if type == "array" then .
      elif .data then .data
      elif .environments then .environments
      elif .agents then .agents
      elif .issues then .issues
      else [] end'
}

# 1. Read the target manifest.
manifest="$(ssh -i "$SSH_KEY" -p 2222 "${SSH_USER}@${HOST}" 'cat /opt/paperclip/environment.json')"
PROJECT_NAME="$(jq -r '.projectName' <<<"$manifest")"
SLUG="$(jq -r '.slug' <<<"$manifest")"
ALIAS="$SLUG"

# 2. Ensure the network exists and attach the target with the alias.
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"
networks_json="$(docker inspect -f '{{json .NetworkSettings.Networks}}' "$CONTAINER")"
if ! printf '%s' "$networks_json" | grep -q "\"$NETWORK\""; then
  docker network connect --alias "$ALIAS" "$NETWORK" "$CONTAINER"
elif ! printf '%s' "$networks_json" | grep -q "\"$ALIAS\""; then
  docker network disconnect "$NETWORK" "$CONTAINER"
  docker network connect --alias "$ALIAS" "$NETWORK" "$CONTAINER"
fi

# 3. Verify the alias resolves from the Paperclip container.
docker exec "$PAPERCLIP_CONTAINER" getent hosts "$ALIAS" >/dev/null || {
  echo "alias $ALIAS not resolvable from $PAPERCLIP_CONTAINER" >&2
  exit 1
}

# 4. Build the environment payload.
SSH_PRIVATE_KEY="$(jq -r '.sshPrivateKey' "$PAPERCLIP_DIR/paperclip-secrets.json")"
env_name="${PROJECT_NAME} devcontainer"
env_body="$(jq -n --arg name "$env_name" --arg slug "$SLUG" --arg ssh "$SSH_PRIVATE_KEY" '{
  name: $name,
  driver: "ssh",
  config: {
    host: $slug,
    port: 2222,
    username: "vscode",
    remoteWorkspacePath: "/workspace",
    privateKeySecretRef: { type: "secret_ref", secretId: $ssh, version: "latest" },
    strictHostKeyChecking: false
  }
}')"

# 5. Upsert the environment by exact name, then probe.
env_ids="$(api "${API}/api/companies/${COMPANY}/environments" | items |
  jq -r --arg name "$env_name" '.[] | select(.name == $name) | .id')"
env_count="$(printf '%s\n' "$env_ids" | grep -c . || true)"
if [ "$env_count" -gt 1 ]; then
  echo "multiple environments named '$env_name'; refusing to guess" >&2
  exit 1
fi
if [ "$env_count" -eq 1 ]; then
  env_id="$env_ids"
  api -X PATCH "${API}/api/environments/${env_id}" -d "$env_body" >/dev/null
else
  env_id="$(api -X POST "${API}/api/companies/${COMPANY}/environments" -d "$env_body" |
    jq -r '.id // .data.id')"
fi
api -X POST "${API}/api/environments/${env_id}/probe" >/dev/null

# 6. Build the agent payload from the template plus project overrides.
TOGETHER_API_KEY="$(jq -r '.togetherApiKey' "$PAPERCLIP_DIR/paperclip-secrets.json")"
render() {
  jq --arg project "$PROJECT_NAME" --arg slug "$SLUG" --arg ws "/workspace" \
     --arg together "$TOGETHER_API_KEY" --arg env "$env_id" '
    walk(if type == "string" then
      gsub("\\{\\{projectName\\}\\}"; $project)
      | gsub("\\{\\{slug\\}\\}"; $slug)
      | gsub("\\{\\{remoteWorkspacePath\\}\\}"; $ws)
      | gsub("\\{\\{togetherApiKey\\}\\}"; $together)
      | gsub("\\{\\{environmentId\\}\\}"; $env)
    else . end)
  '
}
project_override="{}"
[ -f "$PAPERCLIP_DIR/projects/${SLUG}.json" ] && project_override="$(cat "$PAPERCLIP_DIR/projects/${SLUG}.json")"
agent_body="$(jq -s '.[0] * .[1]' "$PAPERCLIP_DIR/agent-template.json" <(printf '%s' "$project_override"))"
agent_body="$(render <<<"$agent_body")"
agent_body="$(jq --arg env "$env_id" '.defaultEnvironmentId = $env' <<<"$agent_body")"

instructions_file="$(jq -r '.instructionsFile // "AGENTS.md"' <<<"$project_override")"
if [ -f "$PAPERCLIP_DIR/$instructions_file" ]; then
  rendered="$(jq -Rrs --arg project "$PROJECT_NAME" --arg slug "$SLUG" --arg ws "/workspace" '
    gsub("\\{\\{projectName\\}\\}"; $project)
    | gsub("\\{\\{slug\\}\\}"; $slug)
    | gsub("\\{\\{remoteWorkspacePath\\}\\}"; $ws)
  ' "$PAPERCLIP_DIR/$instructions_file")"
  agent_body="$(jq --arg file "$instructions_file" --arg content "$rendered" \
    '.instructionsBundle = { entryFile: $file, files: { ($file): $content } }' <<<"$agent_body")"
fi

agent_name="$(jq -r '.agentName // .name // empty' <<<"$agent_body")"
[ -n "$agent_name" ] || agent_name="${PROJECT_NAME} Agent"
agent_body="$(jq --arg name "$agent_name" 'del(.agentName) | .name = $name' <<<"$agent_body")"

agent_ids="$(api "${API}/api/companies/${COMPANY}/agents" | items |
  jq -r --arg name "$agent_name" '.[] | select(.name == $name) | .id')"
agent_count="$(printf '%s\n' "$agent_ids" | grep -c . || true)"
if [ "$agent_count" -gt 1 ]; then
  echo "multiple agents named '$agent_name'; refusing to guess" >&2
  exit 1
fi
if [ "$agent_count" -eq 1 ]; then
  agent_id="$agent_ids"
  api -X PATCH "${API}/api/agents/${agent_id}" -d "$agent_body" >/dev/null
else
  agent_id="$(api -X POST "${API}/api/companies/${COMPANY}/agents" -d "$agent_body" |
    jq -r '.id // .data.id')"
fi

# 7. Create the first task only when the agent has no open assigned issue.
issue_id=""
if [ -f "$PAPERCLIP_DIR/first-task.json" ]; then
  first_task="$(render <<<"$(cat "$PAPERCLIP_DIR/first-task.json")")"
  open_count="$(api "${API}/api/companies/${COMPANY}/issues?assigneeId=${agent_id}&status=open" |
    items | jq 'length')"
  if [ "$open_count" -eq 0 ]; then
    issue_body="$(jq --arg id "$agent_id" '. + { assigneeId: $id }' <<<"$first_task")"
    issue_id="$(api -X POST "${API}/api/companies/${COMPANY}/issues" -d "$issue_body" |
      jq -r '.identifier // .id // empty')"
  fi
fi

# 8. Report.
echo "environment: ${env_id}"
echo "agent: ${agent_id}"
[ -n "$issue_id" ] && echo "issue: ${issue_id}"
```

The script is idempotent by environment and agent name; it fails rather than guessing if duplicates exist. Re-running after a container rebuild reconnects the new container under the same alias and updates the environment. The issue query/create endpoints are illustrative; adjust them to your Paperclip version.

## Workspace behavior

Paperclip only runs `mkdir -p` on `/workspace`; it does not clone, sync, or upload the project. The target's own workspace mount is the agent's workspace. If `/workspace` is empty, the agent has nothing to work on even though the environment probe succeeds.

## Security

- Key-only SSH: `PubkeyAuthentication yes`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 20`, `PermitUserEnvironment no`.
- `~/.ssh` is `0700` and `authorized_keys` is `0600`, owned by the remote user; copied from the shared file at every start.
- The shared directory contains only public or non-secret fleet config. Secret **IDs** and the company ID are fine; secret values are not.
- The build comments out conflicting sshd directives in other sshd config files (password auth, `PermitRootLogin`, `ListenAddress`, `AllowUsers`, and similar) so an earlier directive cannot weaken the key-only configuration.
- The shared bind mount is read-write at the Docker level because the Feature schema used here does not accept `readonly`; the host is the only writer, files are host-owned `0644`, and targets run as the non-root remote user. Do not write to `/opt/paperclip/shared` from a target.
- `strictHostKeyChecking: false` is the local-network default; there is no pinned host key.
- Every container on `paperclip-net` can reach every other container's ports; keep the network dedicated to Paperclip and targets.
- Do not combine with `ghcr.io/devcontainers/features/sshd`.

## Troubleshooting

Run the doctor as the remote user:

```bash
ssh -i ~/.ssh/paperclip-<project> -p 2222 vscode@<alias> paperclip-agent-doctor --json
```

Checks go to stderr; stdout is the JSON document. Without `--json`, stdout is the manifest.

| Symptom | Check |
| --- | --- |
| Container will not start | The host `~/.paperclip` bind source is missing. `mkdir -p ~/.paperclip/projects` on the host. |
| `Permission denied (publickey)` | `/opt/paperclip/shared/authorized_keys` exists and is non-empty; the entrypoint ran; `~/.ssh/authorized_keys` is `0600`. |
| `claude: command not found` over SSH | Paperclip sources `/etc/profile`; a manual `ssh host claude` may need `. /etc/profile` first. |
| `togetherlink` prompts for auth | Add `agent-home`, or run `togetherlink configure` in the target. |
| MCP servers absent in a run | The agent template's `--mcp-config` must point at `/opt/paperclip/shared/mcp-extra.json`. |
| `paperclip_api_dns` fails | The target is not on `paperclip-net`, or the control plane lacks the `paperclip-control` alias. |
| Alias not resolvable from Paperclip | Re-run the host-side `enroll.sh`; it reconnects the container under the slug alias. |

Useful commands inside the target:

```bash
/usr/sbin/sshd -t -f /etc/ssh/sshd_config
/usr/sbin/sshd -T | grep -Ei 'port|maxauthtries|passwordauth|permitroot|allowusers|authorizedkeysfile'
ss -ltn
cat /opt/paperclip/environment.json
cat /opt/paperclip/shared/paperclip.env 2>/dev/null
cat /etc/profile.d/paperclip-agent.sh
```

## Manual verification

This repository has no Feature test harness, so the acceptance procedure is manual. On a Docker host with the devcontainer CLI:

1. Create the host directory and populate it:

   ```bash
   mkdir -p ~/.paperclip/projects
   ssh-keygen -t ed25519 -f ~/.ssh/paperclip_agents -N '' -C paperclip
   cat ~/.ssh/paperclip_agents.pub > ~/.paperclip/authorized_keys
   ```

   Add `mcp-extra.json`, `paperclip.env`, `paperclip-secrets.json`, and `agent-template.json`.

2. Build with no options and with only `projectName` set; confirm both work.

3. Inside the target:

   ```bash
   /usr/sbin/sshd -t -f /etc/ssh/sshd_config
   paperclip-agent-doctor --json | jq .
   cat /opt/paperclip/environment.json
   ```

   Confirm `containerId`, `projectName`, `slug`, and `network.alias` are correct.

4. From another container on `paperclip-net`:

   ```bash
   ssh -i ~/.ssh/paperclip_agents -p 2222 vscode@<slug> 'claude --version && togetherlink --version'
   ```

5. With `authorized_keys` or `mcp-extra.json` missing, confirm the doctor fails and enrollment stops.

6. Enroll a target: the script creates `paperclip-net` if needed, attaches the container with the slug alias, the environment probes at `<slug>:2222`, and `docker port <container> 2222` is empty.

7. Re-run enrollment after recreating the target; the script reconnects the new container and the environment still probes.

8. Confirm the Compose target with `external: true` and the image target with `runArgs` both resolve their aliases.

9. Confirm there is no `paperclip-agent-enroll` binary, no `paperclip-agent-state` volume, no baked MCP default, and no `claude` wrapper.

## Maintenance

This Feature depends on the on-disk layouts of [`claude-code`](../claude-code) and [`together-link`](../together-link), both of which are explicitly early-stage. If either changes, re-check these invariants:

1. **`claude-code` install locations.** The Feature probes `command -v claude`, `/opt/claude-code/bin/claude`, `/usr/local/share/nvm/current/bin/claude`, `${HOME}/.local/bin/claude`, and `$(npm prefix -g)/bin/claude`. The isolated bootstrap keeps Node at `/opt/claude-code/node/bin`.
2. **`together-link` layout.** Binaries are at `/opt/together-link/bin/togetherlink`; `TOGETHERLINK_HOME` is `/opt/together-link`; config is `$HOME/.togetherlink/config.json`; Bun is at `$HOME/.bun/bin`.
3. **The `/etc/profile.d` PATH contract.** Paperclip sources `/etc/profile` before running the agent command. Do not rename `/etc/profile.d/paperclip-agent.sh`. Keep `${HOME}` unexpanded in the file.
4. **Fixed constants.** `2222`, `/workspace`, `/opt/paperclip/shared`, and `paperclip-net` are the contract the control plane and enrollment script depend on. Change them only together.
5. **Shared filenames.** `authorized_keys`, `mcp-extra.json`, `paperclip.env`, `paperclip-secrets.json`, `agent-template.json`, `AGENTS.md`, `first-task.json`, and `projects/<slug>.json` are the schema. Keep the names stable.
6. **Slug derivation order.** top-level git origin, then immediate child repositories when `/workspace` is not a work tree, then `package.json`/`pyproject.toml`/`Cargo.toml`, then the workspace basename, then the hostname. The slug is capped at 63 characters and is the network alias and upsert key.
7. **Host-side enrollment.** The `enroll.sh` in this README is the only enrollment path; there is no target-side binary. Keep its network-connect and upsert logic in sync with the manifest fields.
8. **Versioning.** The Feature is unreleased at `1.0.0`. Bump `version` in `devcontainer-feature.json` for each release, then run the repository's **Release dev container features** workflow and mark the GHCR package public.
