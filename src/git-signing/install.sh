#!/usr/bin/env bash
set -euo pipefail

# Writes SSH signing configuration into the container's *system* git config, so
# that containers which should sign (work machines) do, without putting signing
# into the shared ~/.gitconfig that also runs on the host.
#
# Why /etc/gitconfig:
#   - ~/.gitconfig belongs to the user. Here it is a symlink into a dotfiles
#     repo installed at container start, so appending to it would either be
#     clobbered or race with that install.
#   - The system config is read first, so repo-local config still wins over
#     these defaults (a project can override them deliberately).
#
# Why gpg.ssh.program is unset by default:
#   The editor forwards the host's SSH agent into the container
#   (SSH_AUTH_SOCK), so ssh-keygen signs with a 1Password-managed key with no
#   1Password binary present. A host path such as
#   /Applications/1Password.app/Contents/MacOS/op-ssh-sign does not exist on
#   Linux and makes every signed commit fail, so it is warned about here.

SIGNING_KEY="${SIGNINGKEY:-}"
SIGNING_PROGRAM="${SIGNINGPROGRAM:-}"
SIGN_COMMITS="${SIGNCOMMITS:-true}"
SIGN_TAGS="${SIGNTAGS:-true}"

GITCONFIG="/etc/gitconfig"
BEGIN_MARKER="# >>> git-signing (managed by the git-signing devcontainer Feature) >>>"
END_MARKER="# <<< git-signing (managed by the git-signing devcontainer Feature) <<<"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Quotes a value for git's config syntax, which strips comments unless quoted.
quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# Options arrive as strings; anything but "false" means the default (on).
is_true() {
  [ "${1,,}" != "false" ]
}

# --- validate the signing key ------------------------------------------------

# An empty key would leave commit.gpgsign on with nothing to sign with, which
# fails every commit in the container. Fail the build instead, where it is cheap
# to notice. The option has an empty default because the Feature schema requires
# one, so this check is what actually enforces it.
[ -n "$SIGNING_KEY" ] || die "the signingKey option is required: pass the public key git should sign with."

case "$SIGNING_KEY" in
  ssh-ed25519\ * | ssh-rsa\ * | ssh-dss\ * | ecdsa-sha2-*\ * | sk-ssh-*\ * | sk-ecdsa-*\ * | key::*)
    ;;
  */* | "~"*)
    ;; # a path to a public key file
  *)
    die "signingKey does not look like an SSH public key or a path: '${SIGNING_KEY}'.
       Expected 'ssh-ed25519 AAAA...', a key:: literal, or a path to a public key file."
    ;;
esac

# --- warn about a signing program that cannot run in this image --------------

# Not fatal: the binary may arrive at container start through a mount. Signing
# fails loudly at the first commit if it never does.
if [ -n "$SIGNING_PROGRAM" ] && [ ! -x "$SIGNING_PROGRAM" ]; then
  cat >&2 <<EOF
WARNING: gpg.ssh.program is set to '${SIGNING_PROGRAM}', which is not an
executable file in this image, so signed commits and tags will fail unless that
path appears when the container starts (for example via a mount). Host paths
such as 1Password's /Applications/1Password.app/Contents/MacOS/op-ssh-sign do
not exist in a Linux container; leave signingProgram unset to sign through the
forwarded SSH agent with ssh-keygen instead.
EOF
fi

# --- write the configuration -------------------------------------------------

# Rebuilds are possible, so drop any block a previous install wrote.
if [ -f "$GITCONFIG" ] && grep -qF "$BEGIN_MARKER" "$GITCONFIG"; then
  sed -i "\|^${BEGIN_MARKER}\$|,\|^${END_MARKER}\$|d" "$GITCONFIG"
fi

# Preserve whatever is already in the file (a base image's system config, or
# entries another Feature added) and only ever append.
[ -f "$GITCONFIG" ] || : > "$GITCONFIG"
chmod 644 "$GITCONFIG"

# A file without a trailing newline would swallow the marker line.
if [ -s "$GITCONFIG" ] && [ -n "$(tail -c 1 "$GITCONFIG")" ]; then
  echo >> "$GITCONFIG"
fi

{
  echo "$BEGIN_MARKER"
  printf '[user]\n\tsigningkey = %s\n' "$(quote "$SIGNING_KEY")"
  printf '[gpg]\n\tformat = ssh\n'
  if [ -n "$SIGNING_PROGRAM" ]; then
    printf '[gpg "ssh"]\n\tprogram = %s\n' "$(quote "$SIGNING_PROGRAM")"
  fi
  if is_true "$SIGN_COMMITS"; then
    printf '[commit]\n\tgpgsign = true\n'
  fi
  if is_true "$SIGN_TAGS"; then
    printf '[tag]\n\tgpgsign = true\n'
  fi
  echo "$END_MARKER"
} >> "$GITCONFIG"

echo "Wrote signing configuration to ${GITCONFIG}:"
sed -n "\|^${BEGIN_MARKER}\$|,\|^${END_MARKER}\$|p" "$GITCONFIG"

# --- read the configuration back ---------------------------------------------

# Verifies git itself parses the file, not just that the text was appended.
# Skipped when git is not in the image: the configuration is inert until
# something installs git anyway.
if command -v git >/dev/null 2>&1; then
  if ! format="$(git config --system --get gpg.format)"; then
    die "git cannot read back gpg.format from ${GITCONFIG}."
  fi
  [ "$format" = "ssh" ] || die "expected gpg.format=ssh in ${GITCONFIG}, got '${format}'."
  echo "Verified: git reports gpg.format=${format} and signingkey=$(git config --system --get user.signingkey)"
fi
