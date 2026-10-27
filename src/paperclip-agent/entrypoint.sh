#!/bin/sh
# Entrypoint installed by the paperclip-agent devcontainer Feature.
#
# The devcontainer CLI chains feature entrypoints and passes the container's
# command as arguments, so this script runs as root at container start and ends
# with `exec "$@"` to hand control back to the image/devcontainer command.
#
# Fixed contract: sshd on 2222, workspace /workspace, shared config at
# /opt/paperclip/shared, network paperclip-net, network alias = project slug.
#
# Responsibilities:
#   - copy the shared authorized_keys into the remote user's ~/.ssh;
#   - derive the project name/slug and write /opt/paperclip/environment.json;
#   - generate default SSH host keys if the image has none;
#   - start sshd if it is not already running.
#
# This script never exits non-zero. A broken sshd must not take down the
# container: `paperclip-agent-doctor` reports the failure.

set -u

SHARED_DIR="/opt/paperclip/shared"
AUTHORIZED_KEYS="${SHARED_DIR}/authorized_keys"
MCP_CONFIG="${SHARED_DIR}/mcp-extra.json"
MANIFEST="/opt/paperclip/environment.json"
USER_FILE="/etc/paperclip-agent/user"
PROJECT_FILE="/etc/paperclip-agent/project-name"
NETWORK_NAME="paperclip-net"
REMOTE_WORKSPACE="/workspace"
SSH_PORT=2222

log() {
  printf 'paperclip-agent: %s\n' "$*" >&2
}

sshd_is_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x sshd >/dev/null 2>&1
    return
  fi
  for _pa_pid in /proc/[0-9]*; do
    [ "$(cat "${_pa_pid}/comm" 2>/dev/null)" = "sshd" ] && return 0
  done
  return 1
}

json_escape() {
  printf '%s' "$1" | tr '\n\r' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

resolve_user() {
  _pa_user=""
  [ -r "$USER_FILE" ] && _pa_user=$(cat "$USER_FILE" 2>/dev/null || true)
  [ -n "$_pa_user" ] || _pa_user="vscode"
  if command -v getent >/dev/null 2>&1; then
    _pa_home=$(getent passwd "$_pa_user" 2>/dev/null | cut -d: -f6 || true)
  else
    _pa_home=$(awk -F: -v u="$_pa_user" '$1 == u { print $6; exit }' /etc/passwd)
  fi
}

# Copy the shared key file into the remote user's ~/.ssh. The host is the only
# writer; rotating the shared file takes effect on the next container start.
refresh_authorized_keys() {
  resolve_user
  if [ -z "$_pa_home" ] || [ ! -d "$_pa_home" ]; then
    log "remote user ${_pa_user:-unknown} has no home directory; skipping authorized_keys"
    return 0
  fi

  _pa_ssh_dir="${_pa_home}/.ssh"
  _pa_authorized_keys="${_pa_ssh_dir}/authorized_keys"
  _pa_group=$(id -gn "$_pa_user" 2>/dev/null || true)

  if [ "$(id -u)" = "0" ] && [ -n "$_pa_group" ]; then
    install -d -m 700 -o "$_pa_user" -g "$_pa_group" "$_pa_ssh_dir" 2>/dev/null ||
      { mkdir -p "$_pa_ssh_dir" 2>/dev/null || true; chown "$_pa_user:$_pa_group" "$_pa_ssh_dir" 2>/dev/null || true; chmod 700 "$_pa_ssh_dir" 2>/dev/null || true; }
  else
    mkdir -p "$_pa_ssh_dir" 2>/dev/null || true
    chmod 700 "$_pa_ssh_dir" 2>/dev/null || true
  fi

  if [ -f "$AUTHORIZED_KEYS" ]; then
    cp "$AUTHORIZED_KEYS" "$_pa_authorized_keys" 2>/dev/null ||
      log "could not copy ${AUTHORIZED_KEYS}"
    if [ "$(id -u)" = "0" ] && [ -n "$_pa_group" ]; then
      chown "$_pa_user:$_pa_group" "$_pa_authorized_keys" 2>/dev/null || true
    fi
    chmod 600 "$_pa_authorized_keys" 2>/dev/null || true
  else
    log "${AUTHORIZED_KEYS} is missing; SSH key auth will fail"
  fi
}

slugify() {
  # Docker network aliases are DNS labels, so cap the slug at 63 characters.
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-63 | sed -e 's/-$//'
}

# Derive the project name in the documented order. The first non-empty value
# wins; the slug is used as the network alias and enrollment upsert key.
derive_project_name() {
  _pa_project=""
  [ -r "$PROJECT_FILE" ] && _pa_project=$(cat "$PROJECT_FILE" 2>/dev/null || true)
  _pa_project=$(printf '%s' "$_pa_project" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -n "$_pa_project" ]; then
    printf '%s\n' "$_pa_project"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    if git -C "$REMOTE_WORKSPACE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      # The workspace itself is a git work tree (or a subdirectory of one).
      # Use its origin; if it has none, fall through to workspace metadata and
      # the basename rather than guessing from child repositories.
      _pa_remote=$(git -C "$REMOTE_WORKSPACE" remote get-url origin 2>/dev/null || true)
      if [ -n "$_pa_remote" ]; then
        _pa_project=${_pa_remote##*/}
        _pa_project=${_pa_project%.git}
        if [ -n "$_pa_project" ]; then
          printf '%s\n' "$_pa_project"
          return 0
        fi
      fi
    else
      # The workspace is a container for independent repositories. Use its
      # immediate child repositories: one child uses its origin name (or its
      # directory name without an origin); multiple children use their sorted
      # directory names joined with '-'. Nested repositories are not scanned.
      _pa_child_count=0
      _pa_first_child=""
      _pa_children=""
      for _pa_child in "$REMOTE_WORKSPACE"/*; do
        [ -d "$_pa_child" ] || continue
        [ -e "${_pa_child}/.git" ] || continue
        _pa_child_name=$(basename "$_pa_child")
        [ "$_pa_child_name" = "node_modules" ] && continue
        _pa_child_count=$((_pa_child_count + 1))
        [ -n "$_pa_first_child" ] || _pa_first_child="$_pa_child"
        _pa_children="${_pa_children}${_pa_children:+
}${_pa_child_name}"
      done

      if [ "$_pa_child_count" -eq 1 ]; then
        _pa_child_remote=$(git -C "$_pa_first_child" remote get-url origin 2>/dev/null || true)
        _pa_project=""
        if [ -n "$_pa_child_remote" ]; then
          _pa_project=${_pa_child_remote##*/}
          _pa_project=${_pa_project%.git}
        fi
        [ -n "$_pa_project" ] || _pa_project=$(basename "$_pa_first_child")
        printf '%s\n' "$_pa_project"
        return 0
      elif [ "$_pa_child_count" -gt 1 ]; then
        _pa_project=$(printf '%s\n' "$_pa_children" | sort -u | tr '\n' '-' | sed -e 's/-$//')
        if [ -n "$_pa_project" ]; then
          printf '%s\n' "$_pa_project"
          return 0
        fi
      fi
    fi
  fi

  if [ -f "${REMOTE_WORKSPACE}/package.json" ]; then
    _pa_project=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${REMOTE_WORKSPACE}/package.json" | head -n 1)
    if [ -n "$_pa_project" ]; then
      printf '%s\n' "$_pa_project"
      return 0
    fi
  fi

  if [ -f "${REMOTE_WORKSPACE}/pyproject.toml" ]; then
    _pa_project=$(awk '
      /^\[project\]/ { inproject = 1; next }
      /^\[/ { inproject = 0 }
      inproject && /^[[:space:]]*name[[:space:]]*=/ {
        line = $0
        sub(/^[^=]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        gsub(/^["'"'"']|["'"'"']$/, "", line)
        print line
        exit
      }
    ' "${REMOTE_WORKSPACE}/pyproject.toml")
    if [ -n "$_pa_project" ]; then
      printf '%s\n' "$_pa_project"
      return 0
    fi
  fi

  if [ -f "${REMOTE_WORKSPACE}/Cargo.toml" ]; then
    _pa_project=$(awk '
      /^\[package\]/ { inpackage = 1; next }
      /^\[/ { inpackage = 0 }
      inpackage && /^[[:space:]]*name[[:space:]]*=/ {
        line = $0
        sub(/^[^=]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        gsub(/^["'"'"']|["'"'"']$/, "", line)
        print line
        exit
      }
    ' "${REMOTE_WORKSPACE}/Cargo.toml")
    if [ -n "$_pa_project" ]; then
      printf '%s\n' "$_pa_project"
      return 0
    fi
  fi

  _pa_project=$(basename "$REMOTE_WORKSPACE" 2>/dev/null || true)
  if [ -n "$_pa_project" ]; then
    printf '%s\n' "$_pa_project"
    return 0
  fi

  _pa_project="${HOSTNAME:-}"
  [ -n "$_pa_project" ] || _pa_project=$(hostname 2>/dev/null || true)
  [ -n "$_pa_project" ] || _pa_project="agent"
  printf '%s\n' "$_pa_project"
}

write_manifest() {
  _pa_project=$(derive_project_name)
  _pa_slug=$(slugify "$_pa_project")
  [ -n "$_pa_slug" ] || _pa_slug="agent"

  _pa_hostname="${HOSTNAME:-}"
  [ -n "$_pa_hostname" ] || _pa_hostname=$(hostname 2>/dev/null || true)
  [ -n "$_pa_hostname" ] || _pa_hostname="unknown"

  mkdir -p "$(dirname "$MANIFEST")" 2>/dev/null || true
  cat >"$MANIFEST" <<EOF
{
  "containerId": "$(json_escape "$_pa_hostname")",
  "hostname": "$(json_escape "$_pa_hostname")",
  "projectName": "$(json_escape "$_pa_project")",
  "slug": "$(json_escape "$_pa_slug")",
  "network": { "name": "${NETWORK_NAME}", "alias": "$(json_escape "$_pa_slug")" },
  "remoteWorkspacePath": "${REMOTE_WORKSPACE}",
  "mcpConfigPath": "${MCP_CONFIG}",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  chmod 0644 "$MANIFEST" 2>/dev/null || true
}

ensure_host_keys() {
  # ssh-keygen -A only creates keys that are missing, so this is safe on every
  # start and also fills in a type the image did not ship.
  ssh-keygen -A >/dev/null 2>&1 || log "could not generate SSH host keys"
}

refresh_authorized_keys
write_manifest

mkdir -p /run/sshd 2>/dev/null || true
chmod 0755 /run/sshd 2>/dev/null || true
ensure_host_keys

_pa_sshd_bin="$(command -v sshd 2>/dev/null || true)"
[ -n "$_pa_sshd_bin" ] || _pa_sshd_bin="/usr/sbin/sshd"
if sshd_is_running; then
  log "sshd is already running"
elif "$_pa_sshd_bin"; then
  log "started sshd on port ${SSH_PORT}"
else
  log "sshd failed to start; run 'paperclip-agent-doctor' for details"
fi

exec "$@"
