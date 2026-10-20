# Dev Container Features

A collection of [dev container Features](https://containers.dev/implementors/features/) published to GitHub Container Registry (GHCR).

## Getting started

Don't have a `.devcontainer/` in your project yet? Run one of these from your project root to copy this repo's `devcontainer.json` into the right place:

```bash
# curl
mkdir -p .devcontainer && curl -fsSL https://raw.githubusercontent.com/aj-foster/devcontainer-features/main/.devcontainer/devcontainer.json -o .devcontainer/devcontainer.json
```

## Features

### `agent-home`

Bind-mounts host Cursor, Claude Code, and shared `~/.agents` config into the container so MCP settings, skills, and rules stay in sync with the host.

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "features": {
        "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {}
    }
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

### `claude-code`

Installs the Claude Code CLI as the remote user so its built-in auto-update can replace the install in place. Prefer this over `ghcr.io/anthropics/devcontainer-features/claude-code`, which installs as root and breaks in-place auto-update (`no write permission to npm prefix`).

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "features": {
        "ghcr.io/aj-foster/devcontainer-features/claude-code:1": {}
    }
}
```

Or enable it for all containers via user settings (alongside `agent-home`; remove any Anthropic `claude-code` entry):

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {},
  "ghcr.io/aj-foster/devcontainer-features/claude-code:1": {}
}
```

Uses `npm` when it is already on PATH (and waits for `ghcr.io/devcontainers/features/node` when that Feature is listed). Otherwise it bootstraps an isolated Node.js under `/opt/claude-code` and exposes only `claude`. See [src/claude-code](./src/claude-code) for options and details.

### `together-link`

Installs the [Together Link](https://www.together.ai/link) CLI (`togetherlink`) as the remote user, with binaries isolated under `/opt/together-link` so that cross-mounting `~/.togetherlink` (via `agent-home`) shares only config/auth/sessions — never binaries — and the CLI's self-update never rewrites the host's install.

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:debian",
    "features": {
        "ghcr.io/aj-foster/devcontainer-features/together-link:1": {}
    }
}
```

Or enable it for all containers via user settings (alongside `agent-home`):

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {},
  "ghcr.io/aj-foster/devcontainer-features/together-link:1": {}
}
```

Bootstraps [Bun](https://bun.sh) if it is missing; no Node Feature required. Together Link is early-stage — see [src/together-link](./src/together-link) for the config/binary split and a maintenance guide for when the upstream installer or CLI layout changes.

### `git-signing`

Writes SSH commit and tag signing configuration into the container's system git config (`/etc/gitconfig`), signing through the SSH agent the editor forwards into the container. Meant for the containers that should sign (work) rather than every container: enable it per machine via user settings, so the shared `~/.gitconfig` stays signing-free.

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:debian",
    "features": {
        "ghcr.io/aj-foster/devcontainer-features/git-signing:1": {
            "signingKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@host"
        }
    }
}
```

Or enable it for all containers on a machine that should sign:

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/git-signing:1": {
    "signingKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@host"
  }
}
```

Leaves `gpg.ssh.program` unset by default so git uses `ssh-keygen` with the forwarded agent — no 1Password binary needs to exist in the container. See [src/git-signing](./src/git-signing) for options, verification, and [what to do when signing fails](./src/git-signing/README.md#when-signing-fails).

## Repo structure

```
├── src
│   ├── agent-home
│   │   ├── devcontainer-feature.json
│   │   ├── install.sh
│   │   └── README.md
│   ├── claude-code
│   │   ├── devcontainer-feature.json
│   │   ├── install.sh
│   │   ├── bootstrap-node.sh
│   │   └── README.md
│   ├── git-signing
│   │   ├── devcontainer-feature.json
│   │   ├── install.sh
│   │   └── README.md
│   └── together-link
│       ├── devcontainer-feature.json
│       ├── install.sh
│       └── README.md
└── .github/workflows
    └── release.yaml
```

Each Feature lives under `src/<id>/` with at least a `devcontainer-feature.json` and `install.sh`.

## Publishing

Features are versioned via the `version` field in `devcontainer-feature.json` (semver). Publishing is handled by [`.github/workflows/release.yaml`](.github/workflows/release.yaml), based on [`devcontainers/feature-starter`](https://github.com/devcontainers/feature-starter).

1. Bump `version` in the Feature's `devcontainer-feature.json` when you want a new release.
2. Merge to `main`.
3. Run **Release dev container features** from the Actions tab (`workflow_dispatch`).
4. After the first publish, mark each GHCR package public (Settings → Packages) so it stays within the free tier:
   - `https://github.com/users/aj-foster/packages/container/devcontainer-features%2Fagent-home/settings`
   - `https://github.com/users/aj-foster/packages/container/devcontainer-features%2Fclaude-code/settings`
   - `https://github.com/users/aj-foster/packages/container/devcontainer-features%2Fgit-signing/settings`
   - `https://github.com/users/aj-foster/packages/container/devcontainer-features%2Ftogether-link/settings`

Published references:

```
ghcr.io/aj-foster/devcontainer-features/agent-home:1
ghcr.io/aj-foster/devcontainer-features/claude-code:1
ghcr.io/aj-foster/devcontainer-features/git-signing:1
ghcr.io/aj-foster/devcontainer-features/together-link:1
```

A collection metadata package is also published at `ghcr.io/aj-foster/devcontainer-features`.
