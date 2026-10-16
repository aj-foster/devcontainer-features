# Together Link

Installs the [Together Link](https://www.together.ai/link) CLI (`togetherlink`) for the remote user, with binaries isolated under `/opt/together-link` so a shared `~/.togetherlink` carries only config/auth/sessions and the CLI's in-place self-update never rewrites a host install.

## What it does

Runs Together Link's official installer (`curl -fsSL https://link.together.ai/install | bash`) as the remote user with `TOGETHERLINK_HOME=/opt/together-link` and `TOGETHERLINK_NO_LAUNCH=1`. That installs a Bun-target JS bundle plus the `togetherlink`/`tlink`/`tclaude`/`tcodex`/… wrappers under `/opt/together-link/bin`, bootstrapping [Bun](https://bun.sh) into the user's `~/.bun` if it is missing (which needs `curl` and `unzip`; the Feature installs them via `apt-get` when absent).

`containerEnv` puts `/opt/together-link/bin` on `PATH` and exports `TOGETHERLINK_HOME=/opt/together-link`.

## The `/opt` split (why `TOGETHERLINK_HOME` is set)

The point is to cross-mount **config/auth/sessions** without cross-mounting **binaries**. Two facts about the CLI (verified against the bundle — see Maintenance) make this work:

| State | Resolved from | Location with this Feature |
| --- | --- | --- |
| `config.json` (API key / profile) | `$HOME` (ignores `TOGETHERLINK_HOME`) | `~/.togetherlink/config.json` — **shared** when [`agent-home`](../agent-home) mounts `~/.togetherlink` |
| Bundle + wrappers, self-update target | `$TOGETHERLINK_HOME` | `/opt/together-link/bin` — **container-local** |
| `.gateway-url`, `.update-manifest-url`, `status-spend/` | `$TOGETHERLINK_HOME` | `/opt/together-link` — container-local |

So the auth is shared via the mount, while binaries and self-updates stay in the image. Because self-update writes to `$TOGETHERLINK_HOME/bin/togetherlink.js`, pointing `TOGETHERLINK_HOME` at `/opt` is what stops a container's `togetherlink update` from rewriting the **host's** bundle through the bind mount.

Account-level usage/sessions are tracked cloud-side against the API key, so they follow the shared `config.json`; the local `status-spend/` cache is container-local by design and simply rebuilds.

## Requirements

Needs `curl` and `unzip` (for the Bun install); the Feature adds them with `apt-get` if missing. No Node Feature is required — Bun is self-contained. Assumes `remoteUser` is `vscode` (resolved from `_REMOTE_USER`/`_CONTAINER_USER`).

## Using it with `agent-home`

[`agent-home`](../agent-home) bind-mounts `~/.togetherlink` from the host. With this Feature installing binaries to `/opt`, that mount shares only config/auth. If the host itself has Together Link installed the normal way, its `~/.togetherlink/bin` is visible in the container but unused (PATH points at `/opt`) and never written (self-update targets `/opt`).

The host path must exist before the container starts, or the bind mount fails:

```bash
mkdir -p ~/.togetherlink   # or install Together Link on the host first
```

## Options

None.

## Enable via user settings

Alongside [`agent-home`](../agent-home):

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/agent-home:1": {},
  "ghcr.io/aj-foster/devcontainer-features/together-link:1": {}
}
```

Rebuild the container after enabling.

## Maintenance

**Together Link is early-stage and likely to change.** This Feature depends on specifics of the installer and the CLI's on-disk layout. The following was verified **2026-10-16** against bundle **v0.9.86** (`https://gateway.togetherlink.dev/togetherlink.js`, fetched by the installer from `https://link.together.ai/install`). If the Feature breaks, re-verify these invariants and adjust:

1. **Installer contract.** `curl -fsSL https://link.together.ai/install | bash` honors `TOGETHERLINK_HOME` (install dir) and `TOGETHERLINK_NO_LAUNCH=1` (skip the post-install launch prompt), and only needs `curl`/`unzip`/Bun. If it stops honoring either env var, `install.sh` needs updating.
2. **Config is `$HOME`-pinned.** The CLI reads/writes `config.json` at `$HOME/.togetherlink`, *not* `$TOGETHERLINK_HOME`. In the bundle: `_l(e=homedir())=join(Lt(e),"config.json")`, `Lt(e)=join(e,".togetherlink")`, and call sites pass `home: homedir()`. If config ever starts honoring `TOGETHERLINK_HOME`, setting it to `/opt` would move the API key out of the shared mount and break auth sharing — the Feature would then need a different split (e.g. stop setting `TOGETHERLINK_HOME` and solve the self-update-into-mount problem another way).
3. **Self-update is `TOGETHERLINK_HOME`-relative.** The updater writes the bundle to `$TOGETHERLINK_HOME/bin/togetherlink.js` (`oa()=join(Us(),"bin","togetherlink.js")`, `Us()=process.env.TOGETHERLINK_HOME||~/.togetherlink`). This is the whole reason `TOGETHERLINK_HOME=/opt` is set — so a container never rewrites the host's bundle through the mount.

Re-verify by fetching the bundle and grepping the helpers:

```bash
curl -fsSL https://gateway.togetherlink.dev/togetherlink.js -o /tmp/tl.js
grep -oE 'function (Lt|_l|Us|oa)\([^)]*\)\{[^}]{0,120}' /tmp/tl.js   # home/config/update resolvers
grep -oE 'home[:=][^,;){]{0,30}' /tmp/tl.js | sort | uniq -c        # what home config calls receive
```

Symptoms and causes:

- **Build fails during install** → installer URL/flags/prereqs changed (invariant 1).
- **In-container re-prompts for an API key although the host is configured** → config path no longer `$HOME`-pinned (invariant 2).
- **Host `togetherlink` breaks after running the container** → self-update no longer `TOGETHERLINK_HOME`-relative, or `TOGETHERLINK_HOME` not taking effect (invariant 3).
