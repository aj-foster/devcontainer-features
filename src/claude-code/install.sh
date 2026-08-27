#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-latest}"
USERNAME="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"
FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  install_claude_with_npm "${CLAUDE_CODE_NODE_ROOT}/bin/npm" "$CLAUDE_CODE_NODE_ROOT"
  claude_code_install_wrapper

  if ! [ -x "${CLAUDE_CODE_BIN_DIR}/claude" ]; then
    echo "ERROR: isolated claude wrapper was not created at ${CLAUDE_CODE_BIN_DIR}/claude." >&2
    exit 1
  fi

  echo "Installed: $("${CLAUDE_CODE_BIN_DIR}/claude" --version)"
fi
