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
container, and on a host running 1Password that socket *is* 1Password's agent, so
the key never leaves the host and no 1Password binary is needed on Linux. A host
path such as `/Applications/1Password.app/Contents/MacOS/op-ssh-sign` does not
exist in the container and would make every signed commit fail; setting it logs a
warning at build time and is only correct when the binary really is present
inside the image.

## Verifying

On the work machine, in the container:

```bash
git config --system --list | grep -E 'signingkey|gpgsign|format'
ssh-add -l                     # the forwarded agent should list the key
git commit --allow-empty -S -m "signing test"
git log --show-signature -1
```

If `git config --system --list` shows the block but signing fails, check
`ssh-add -l` first: an agent with no identities means the editor did not forward
one, not that the configuration is wrong. If the block is missing entirely, the
editor rewrote `/etc/gitconfig` when the container started; that is the one
failure mode this Feature cannot see at build time.
