#!/usr/bin/env bash
set -euo pipefail

# Together Link ships its own installer (curl -fsSL https://link.together.ai/install
# | bash). It installs a Bun-target JS bundle plus wrappers under
# $TOGETHERLINK_HOME/bin, installing Bun for the user if it is missing.
#
# Two facts about the CLI shape this Feature (verified against the bundle):
#   1. The CLI always reads/writes its config at $HOME/.togetherlink/config.json,
#      ignoring TOGETHERLINK_HOME. That is the auth/profile worth cross-mounting.
#   2. Self-update rewrites the bundle at $TOGETHERLINK_HOME/bin/togetherlink.js.
#
# So we point TOGETHERLINK_HOME at a container-local /opt/together-link: binaries
# and self-updates stay in the image, while config/auth stays in ~/.togetherlink.
# When agent-home bind-mounts ~/.togetherlink from the host, only config/auth is
# shared and the host's own install is never rewritten through the mount.

USERNAME="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"
INSTALL_DIR="/opt/together-link"
INSTALLER_URL="https://link.together.ai/install"

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
USER_HOME="${USER_HOME:-/home/$USERNAME}"
USER_GROUP="$(id -gn "$USERNAME")"

# Bun's installer needs curl and unzip; add them only if the base image lacks them.
missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v unzip >/dev/null 2>&1 || missing+=(unzip)
if [ "${#missing[@]}" -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing prerequisites: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends "${missing[@]}"
  else
    echo "ERROR: need ${missing[*]} but apt-get is unavailable; install them and retry." >&2
    exit 1
  fi
fi

# Keep the install dir container-local and owned by the remote user so the CLI's
# in-place self-update can replace the bundle later.
mkdir -p "$INSTALL_DIR"
chown -R "${USERNAME}:${USER_GROUP}" "$INSTALL_DIR"

echo "Installing Together Link into ${INSTALL_DIR} as ${USERNAME}..."
# Do not use `su -` (login shell): it resets PATH. TOGETHERLINK_NO_LAUNCH keeps
# the installer from trying to start the CLI on this non-interactive shell.
su "$USERNAME" -s /bin/bash -c "
  set -euo pipefail
  export HOME='$USER_HOME'
  export TOGETHERLINK_HOME='$INSTALL_DIR'
  export TOGETHERLINK_NO_LAUNCH=1
  curl -fsSL '$INSTALLER_URL' | bash
"

# Exercise the launcher (resolves the baked Bun path and the installed bundle).
version_check() {
  su "$USERNAME" -s /bin/bash -c "
    export HOME='$USER_HOME'
    export TOGETHERLINK_HOME='$INSTALL_DIR'
    '$INSTALL_DIR/bin/togetherlink' --version
  "
}

if ! installed_version="$(version_check)"; then
  echo "ERROR: togetherlink failed its version check after install." >&2
  exit 1
fi
echo "Installed: ${installed_version}"
