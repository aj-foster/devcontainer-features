#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-latest}"
USERNAME="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"

if ! command -v npm >/dev/null; then
  echo "ERROR: npm not found. Add \"ghcr.io/devcontainers/features/node:1\" to your features." >&2
  exit 1
fi

NPM_BIN="$(command -v npm)"
PREFIX="$(npm prefix -g)"
SPEC="@anthropic-ai/claude-code"
if [ "$VERSION" != "latest" ]; then
  SPEC="${SPEC}@${VERSION}"
fi

# Probe whether the remote user can write into the global npm prefix.
# Prefer installing as that user so ownership is correct from the start.
# Do not use `su -` (login shell): it resets PATH and drops nvm shims.
can_write_as_user() {
  su "$USERNAME" -s /bin/bash -c "test -w '$1'" 2>/dev/null
}

fix_ownership() {
  local pkg_dir="$PREFIX/lib/node_modules/@anthropic-ai"
  local bin_link="$PREFIX/bin/claude"
  local group
  group="$(id -gn "$USERNAME")"

  if [ -d "$pkg_dir" ]; then
    chown -R "${USERNAME}:${group}" "$pkg_dir"
    chmod -R g+w "$pkg_dir"
  fi

  if [ -e "$bin_link" ] || [ -L "$bin_link" ]; then
    chown -h "${USERNAME}:${group}" "$bin_link"
  fi
}

if can_write_as_user "$PREFIX/lib/node_modules" && can_write_as_user "$PREFIX/bin"; then
  echo "Installing ${SPEC} as ${USERNAME} into ${PREFIX}..."
  su "$USERNAME" -s /bin/bash -c "PATH='$PATH' '$NPM_BIN' install -g '$SPEC'"
else
  echo "npm prefix ${PREFIX} is not writable by ${USERNAME}; installing as root then fixing ownership..."
  "$NPM_BIN" install -g "$SPEC"
  fix_ownership
fi

if ! command -v claude >/dev/null; then
  echo "ERROR: claude not found on PATH after install." >&2
  exit 1
fi

echo "Installed: $(claude --version)"
