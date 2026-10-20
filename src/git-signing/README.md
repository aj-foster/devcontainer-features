# Git Signing

Writes SSH commit and tag signing configuration into the container's **system**
git config (`/etc/gitconfig`), signing through the SSH agent the editor forwards
into the container.

The point is the split between machines: load this Feature in the containers that
should sign (work) and not in the ones that shouldn't (personal), by editing
`dev.containers.defaultFeatures` on each machine rather than the shared
`~/.gitconfig` that both machines read.

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

Or, to apply it to every container on one machine only:

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/aj-foster/devcontainer-features/git-signing:1": {
    "signingKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@host"
  }
}
```

Rebuild the container after enabling.

## Options

| Option           | Default | Description                                                                                                                                             |
| ---------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `signingKey`     | `""`    | Public key git signs with: a raw key (`ssh-ed25519 AAAA...`), a `key::` literal, or a path to a public key file. Empty fails the build.                   |
| `signingProgram` | `""`    | Value for `gpg.ssh.program`. Empty omits the setting, so git uses `ssh-keygen` and the forwarded agent. A path that isn't executable in the image warns. |
| `signCommits`    | `true`  | Sets `commit.gpgsign`, so commits are signed without `-S`.                                                                                              |
| `signTags`       | `true`  | Sets `tag.gpgsign`, so tags are signed without `-s`.                                                                                                    |

The key is the only genuinely required option. It has an empty default because
the Feature schema requires a default for every option, so `install.sh` is what
enforces it: an empty or malformed key fails the image build, rather than
producing a container where `commit.gpgsign` is on and every commit fails.

## What it writes

Between markers, so re-installs replace the block instead of appending to it:

```ini
# >>> git-signing (managed by the git-signing devcontainer Feature) >>>
[user]
	signingkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@host"
[gpg]
	format = ssh
[commit]
	gpgsign = true
[tag]
	gpgsign = true
# <<< git-signing (managed by the git-signing devcontainer Feature) <<<
```

`[gpg "ssh"] program` appears only when `signingProgram` is set.

## Why the system config, and why no `gpg.ssh.program` by default

`~/.gitconfig` belongs to the user, and in a dotfiles-managed container it is a
symlink created when the container starts — appending to it at build time would
either be clobbered or race with that install. `/etc/gitconfig` is read first, so
these are defaults a repository can still override deliberately with its own
`.git/config`.

`gpg.ssh.program` is left unset so git uses `ssh-keygen` with whatever agent the
container has. VS Code and Cursor forward the host's `SSH_AUTH_SOCK` into the
container, so if that socket is 1Password's agent the key never leaves the host
and no 1Password binary is needed on Linux. The catch is the "if": the forwarded
socket is only 1Password's when the environment that launches the editor points
`SSH_AUTH_SOCK` at it, and on macOS the default points somewhere else entirely.
See [When signing fails](#when-signing-fails) — this is the assumption that
breaks most often in practice.

A host path such as `/Applications/1Password.app/Contents/MacOS/op-ssh-sign` does
not exist in the container and would make every signed commit fail; setting it
logs a warning at build time and is only correct when the binary really is
present inside the image.

## Verifying

On the work machine, in the container:

```bash
git config --system --list | grep -E 'signingkey|gpgsign|format'
ssh-add -l                     # the forwarded agent should list the key
git commit --allow-empty -S -m "signing test"
git log --show-signature -1
```

If `git config --system --list` shows the block but signing fails, the agent is
the thing to check, not the configuration — see
[When signing fails](#when-signing-fails). If the block is missing entirely, the
editor rewrote `/etc/gitconfig` when the container started; that is the one
failure mode this Feature cannot see at build time.

## When signing fails

This Feature writes configuration. It cannot put a key into an agent, so signing
has two halves that must both work, and the agent half is the one that breaks. A
container whose agent is empty fails on *every* commit, because `commit.gpgsign`
is on:

```
error: Couldn't find key in agent?
fatal: failed to write commit object
```

That message does not mean the configuration is wrong — `/etc/gitconfig` can be
perfectly correct and this still happens. Check the two halves in order:

```bash
git config --system --get user.signingkey   # config half: is the key there?
ssh-add -l                                  # agent half: does it hold anything?
```

`ssh-add -l` exiting 1 with "The agent has no identities" against a socket that
exists means the socket was forwarded and is alive, but the host agent behind it
holds no keys. Confirm on the host, in the environment that launches the editor —
a terminal often has a different `SSH_AUTH_SOCK` than the Dock-launched app:

```bash
echo $SSH_AUTH_SOCK
ssh-add -l
```

### macOS: the default agent is empty

On macOS `SSH_AUTH_SOCK` usually points at
`/var/run/com.apple.launchd.*/Listeners`, the system agent that never holds
identities. The editor forwards that socket, so the container inherits an empty
agent. This is easy to miss on the host, where commits may still sign through a
helper that never consults the socket (see below). If 1Password manages your
keys, point the environment at 1Password's socket:

```bash
# App Store build
launchctl setenv SSH_AUTH_SOCK "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
# direct download
launchctl setenv SSH_AUTH_SOCK "$HOME/.1password/agent.sock"
```

Test the socket before relying on it — it should list the signing key:

```bash
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh-add -l
```

Then quit and relaunch the editor so it picks up the new value. `launchctl
setenv` lasts only until reboot and affects only processes launchd starts
afterwards, so make it stick with a LaunchAgent in `~/Library/LaunchAgents/`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.ssh-auth-sock</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/launchctl</string>
    <string>setenv</string>
    <string>SSH_AUTH_SOCK</string>
    <string>/Users/you/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

The plist needs the literal path: there is no `$HOME` expansion there. The Group
Containers path is specific to the App Store build of 1Password and changes if
you switch to the direct download.

### A host `gpg.ssh.program` hides the empty agent

If the host signs with
`gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign`, host
commits succeed even while `SSH_AUTH_SOCK` points at an empty agent, because
`op-ssh-sign` talks to 1Password directly and never consults the socket. The
container has no such binary, so it fails where the host silently succeeded.
Once the forwarded agent holds the key, that line can go: `ssh-keygen` through
1Password's agent is then the same path on host and container, with no gap left
to hide this class of problem.

### Mounting an agent socket yourself

Docker Desktop's `/run/host-services/ssh-auth.sock`, mounted and pointed at with
`remoteEnv.SSH_AUTH_SOCK`, is for `docker run` and compose, where nothing
forwards an agent. A dev container already gets `SSH_AUTH_SOCK` forwarded, and
that mount proxies the same host agent, so it does not help while the agent is
empty. The path also exists only inside Docker Desktop's VM: on a Linux host the
bind mount silently creates an empty directory instead, and `SSH_AUTH_SOCK`
points at a directory.

### Getting unblocked meanwhile

`commit.gpgsign` is on for every repository in the container, so an empty agent
blocks unrelated work too. Sign one commit without signing, or turn it off for
that repository:

```bash
git -c commit.gpgsign=false commit -m "..."
git config --local commit.gpgsign false
```
