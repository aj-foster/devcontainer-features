# Agent Home

Bind-mounts host Cursor, Claude Code, Copilot CLI, and shared `~/.agents` config into the devcontainer so MCP settings, skills, and rules stay in sync with the host.

This feature is specifically made for devcontainers run by VS Code (or Cursor).

## Mounts

| Host path         | Container path               | Purpose                                        |
| ----------------- | ---------------------------- | ---------------------------------------------- |
| `~/.cursor`       | `/home/vscode/.cursor`       | Cursor MCP, skills, rules                      |
| `~/.claude`       | `/home/vscode/.claude`       | Claude skills, rules, agents, plugins          |
| `~/.claude.json`  | `/home/vscode/.claude.json`  | Claude OAuth / personal MCP                    |
| `~/.copilot`      | `/home/vscode/.copilot`      | Copilot CLI config, skills, auth, sessions     |
| `~/.agents`       | `/home/vscode/.agents`       | Canonical `npx skills` store (symlink targets) |
| `~/.togetherlink` | `/home/vscode/.togetherlink` | Together Link config/auth (`config.json`)      |

`~/.agents` is required for symlink-mode global skills (`npx skills add -g`),
where agent dirs link to `../../.agents/skills/...`.

`~/.copilot` is the Copilot CLI's single config directory (`settings.json`,
`config.json` auth, `skills/`, `session-state/`, `session-store.db`). Sharing it
covers both a standalone `copilot` CLI and the VS Code Agent Host's bundled
`copilotcli` provider, which use the same directory. Sessions also sync to your
GitHub account by default (`remoteExport: true` in `settings.json`), so the mount
mainly shares config, skills, and auth; set `COPILOT_HOME` to relocate the whole
directory if you prefer a different location.

The [`together-link`](../together-link) Feature installs the Together Link CLI
into `/opt/together-link`, so this mount shares only Together Link's
`config.json` (auth/profile). The CLI reads config from `~/.togetherlink`
regardless of where its binaries live, so auth stays in sync with the host while
binaries do not.

Assumes `remoteUser` is `vscode`.

## Host bootstrap (required once)

Bind mounts fail if the source path is missing. On the host:

```bash
mkdir -p ~/.cursor ~/.claude ~/.copilot ~/.agents
touch ~/.claude.json
```

## Enable via user settings

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {}
}
```

Rebuild the container after enabling.
