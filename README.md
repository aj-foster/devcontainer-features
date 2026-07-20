# Dev Container Features

A collection of [devcontainer Features](https://containers.dev/implementors/features/) published to GitHub Container Registry (GHCR).

## Features

### `agent-home`

Bind-mounts host Cursor, Claude Code, and shared `~/.agents` config into the container so MCP settings, skills, and rules stay in sync with the host.

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {},
  },
}
```

Or enable it for all containers via user settings:

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {}
}
```

Assumes `remoteUser` is `vscode`. Host paths must exist before the container starts:

```bash
mkdir -p ~/.cursor ~/.claude ~/.agents
touch ~/.claude.json
```

See [src/agent-home](./src/agent-home) for mounts and details.

## Repo structure

```
├── src
│   └── agent-home
│       ├── devcontainer-feature.json
│       ├── install.sh
│       └── NOTES.md
└── .github/workflows
    └── release.yaml
```

Each Feature lives under `src/<id>/` with at least a `devcontainer-feature.json` and `install.sh`. Custom documentation goes in `NOTES.md`; the release workflow regenerates each Feature's `README.md` from it.

## Publishing

Features are versioned via the `version` field in `devcontainer-feature.json` (semver). Publishing is handled by [`.github/workflows/release.yaml`](.github/workflows/release.yaml), based on [`devcontainers/feature-starter`](https://github.com/devcontainers/feature-starter).

1. Bump `version` in the Feature's `devcontainer-feature.json` when you want a new release.
2. Merge to `main`.
3. Run **Release dev container features & Generate Documentation** from the Actions tab (`workflow_dispatch`).
4. After the first publish, mark each GHCR package public (Settings → Packages) so it stays within the free tier:
   `https://github.com/users/aj-foster/packages/container/devcontainer-features%2Fagent-home/settings`

Enable **Allow GitHub Actions to create and approve pull requests** under Settings → Actions → General so the workflow can open a PR for generated Feature READMEs.

Published references:

```
ghcr.io/aj-foster/devcontainer-features/agent-home:1
```

A collection metadata package is also published at `ghcr.io/aj-foster/devcontainer-features`.
