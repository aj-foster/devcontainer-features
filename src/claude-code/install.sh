#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-latest}"
USERNAME="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"
FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PACKAGE_NAME="@anthropic-ai/claude-code"
SPEC="$PACKAGE_NAME"
if [ "$VERSION" != "latest" ]; then
  SPEC="${SPEC}@${VERSION}"
fi

# npm 11 writes `--location=user` config to $HOME/.npmrc, so resolve the remote
# user's home once and pass it through `su` rather than relying on the su
# implementation to set HOME. getent exits 2 for a missing key, which under
# `set -e` would abort before printing anything, so capture it instead.
if command -v getent >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6 || true)"
else
  USER_HOME="$(awk -F: -v u="$USERNAME" '$1 == u { print $6; exit }' /etc/passwd)"
fi
if [ -z "$USER_HOME" ]; then
  echo "ERROR: remote user '${USERNAME}' does not exist in this image." >&2
  echo "       This Feature installs as the remote user; create it first, or" >&2
  echo "       set remoteUser to a user that exists." >&2
  exit 1
fi

# Probe whether the remote user can write into the global npm prefix.
# Prefer installing as that user so ownership is correct from the start.
# Do not use `su -` (login shell): it resets PATH and drops nvm shims.
can_write_as_user() {
  su "$USERNAME" -s /bin/bash -c "test -w '$1'" 2>/dev/null
}

fix_ownership() {
  local prefix="$1"
  local pkg_dir="$prefix/lib/node_modules/@anthropic-ai"
  local bin_link="$prefix/bin/claude"
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

install_claude_with_npm() {
  local npm_bin="$1"
  local prefix="$2"

  if can_write_as_user "$prefix/lib/node_modules" && can_write_as_user "$prefix/bin"; then
    echo "Installing ${SPEC} as ${USERNAME} into ${prefix}..."
    su "$USERNAME" -s /bin/bash -c "PATH='$PATH' '$npm_bin' install -g --prefix '$prefix' '$SPEC'"
  else
    echo "npm prefix ${prefix} is not writable by ${USERNAME}; installing as root then fixing ownership..."
    "$npm_bin" install -g --prefix "$prefix" "$SPEC"
    fix_ownership "$prefix"
  fi
}

# Claude Code 2.1+ ships bin/claude.exe as a small stub that a postinstall
# (install.cjs) replaces with the platform-native binary. npm 11 treats that
# postinstall as unreviewed and warns on every install; a stricter npm may
# refuse to run it, leaving the stub and breaking auto-update ("postinstall did
# not run"). Pre-approve the bare package name (no version) so every version
# the updater installs is covered. Older npm predating allow-scripts ignores
# the key, so a failure here must not fail the Feature.
preapprove_postinstall() {
  local npm_bin="$1"

  echo "Pre-approving the ${PACKAGE_NAME} postinstall for ${USERNAME}..."
  if ! su "$USERNAME" -s /bin/bash -c "PATH='$PATH' HOME='$USER_HOME' '$npm_bin' config set allow-scripts='${PACKAGE_NAME}' --location=user"; then
    echo "WARNING: could not record allow-scripts in ${USER_HOME}/.npmrc; this npm may predate allow-scripts." >&2
  fi
}

# shellcheck source=bootstrap-node.sh
. "$FEATURE_DIR/bootstrap-node.sh"

if command -v npm >/dev/null; then
  # A previous image layer may have left an isolated runtime; don't shadow a real npm.
  if [ -f "${CLAUDE_CODE_NODE_ROOT}/.bootstrapped-by-claude-code" ]; then
    echo "npm already present; removing leftover isolated Node.js at ${CLAUDE_CODE_ROOT}."
    rm -rf "$CLAUDE_CODE_ROOT"
  fi

  NPM_BIN="$(command -v npm)"
  PREFIX="$(npm prefix -g)"
  preapprove_postinstall "$NPM_BIN"
  install_claude_with_npm "$NPM_BIN" "$PREFIX"

  if ! command -v claude >/dev/null; then
    echo "ERROR: claude not found on PATH after install." >&2
    exit 1
  fi

  echo "Installed: $(claude --version)"
else
  echo "npm not found; bootstrapping an isolated Node.js for Claude Code..."
  claude_code_bootstrap_node "$USERNAME"

  PATH="${CLAUDE_CODE_NODE_ROOT}/bin:${PATH}"
  export PATH
  preapprove_postinstall "${CLAUDE_CODE_NODE_ROOT}/bin/npm"
  install_claude_with_npm "${CLAUDE_CODE_NODE_ROOT}/bin/npm" "$CLAUDE_CODE_NODE_ROOT"
  claude_code_install_wrapper

  if ! [ -x "${CLAUDE_CODE_BIN_DIR}/claude" ]; then
    echo "ERROR: isolated claude wrapper was not created at ${CLAUDE_CODE_BIN_DIR}/claude." >&2
    exit 1
  fi

  echo "Installed: $("${CLAUDE_CODE_BIN_DIR}/claude" --version)"
fi
