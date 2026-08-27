# Claude Code

Installs the Claude Code CLI (`@anthropic-ai/claude-code`) as the remote user so its built-in auto-update can replace the install in place.

## Why this exists

[`ghcr.io/anthropics/devcontainer-features/claude-code`](https://github.com/anthropics/devcontainer-features) runs `npm install -g` as root during feature install. The package tree and `bin/claude` symlink end up root-owned inside an otherwise user-writable npm prefix. Auto-update then fails with:

```
✘ Auto-update failed: no write permission to npm prefix · Run claude doctor
```

This feature installs (or chowns) as the remote user so `claude update` can succeed.

## Requirements

Uses `npm` if it is already on PATH. `installsAfter` waits for [`ghcr.io/devcontainers/features/node`](https://github.com/devcontainers/features/tree/main/src/node) when that Feature is also enabled, so project Node options are honored.

If `npm` is still missing, this Feature downloads the current Node.js LTS into an isolated prefix and does **not** put `node` or `npm` on PATH. Only a `claude` wrapper is exposed:

| Path | Role |
| --- | --- |
| `/opt/claude-code/node` | Private Node.js + npm prefix (owned by the remote user) |
| `/opt/claude-code/bin/claude` | Wrapper that prepends the private `bin` for that process only |

Add the Node Feature if the project itself needs Node.js:

```json
"ghcr.io/devcontainers/features/node:1": {}
```

## Options

| Option    | Type   | Default  | Description                                                      |
| --------- | ------ | -------- | ---------------------------------------------------------------- |
| `version` | string | `latest` | npm dist-tag or exact version of `@anthropic-ai/claude-code` |

## Warning: do not combine with Anthropic's feature

Do **not** enable this alongside `ghcr.io/anthropics/devcontainer-features/claude-code`. Both install the same global package; whichever runs last wins, and a root-owned Anthropic install can silently reintroduce the auto-update bug.

## Enable via user settings

Alongside [`agent-home`](../agent-home):

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {},
  "ghcr.io/aj-foster/devcontainer-features/claude-code:1": {}
}
```

Remove any Anthropic `claude-code` entry from this setting, then rebuild the container.
