# Agent Home

Bind-mounts host Cursor, Claude Code, and shared `~/.agents` config into the devcontainer so MCP settings, skills, and rules stay in sync with the host.

This feature is specifically made for devcontainers run by VS Code (or Cursor).

## Mounts

| Host path        | Container path              | Purpose                                        |
| ---------------- | --------------------------- | ---------------------------------------------- |
| `~/.cursor`      | `/home/vscode/.cursor`      | Cursor MCP, skills, rules                      |
| `~/.claude`      | `/home/vscode/.claude`      | Claude skills, rules, agents, plugins          |
| `~/.claude.json` | `/home/vscode/.claude.json` | Claude OAuth / personal MCP                    |
| `~/.agents`      | `/home/vscode/.agents`      | Canonical `npx skills` store (symlink targets) |

`~/.agents` is required for symlink-mode global skills (`npx skills add -g`),
where agent dirs link to `../../.agents/skills/...`.

Assumes `remoteUser` is `vscode`.

## Host bootstrap (required once)

Bind mounts fail if the source path is missing. On the host:

```bash
mkdir -p ~/.cursor ~/.claude ~/.agents
touch ~/.claude.json
```

## Enable via user settings

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {}
}
```

Rebuild the container after enabling.
