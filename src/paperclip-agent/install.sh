#!/usr/bin/env bash
set -euo pipefail

# Prepares the *target* side of a Paperclip SSH environment on the shared
# paperclip-net Docker network.
#
# Fixed contract (the control plane and the host-side enrollment script depend
# on these values):
#   sshd port              2222
#   remote workspace       /workspace
#   shared config          /opt/paperclip/shared (host ~/.paperclip)
#   network                paperclip-net
#   network alias          the project slug
#   MCP config             /opt/paperclip/shared/mcp-extra.json
#   authorized keys        /opt/paperclip/shared/authorized_keys
#   shared env             /opt/paperclip/shared/paperclip.env
#
# The shared directory is mounted by the Feature metadata and is not available
# during the image build. entrypoint.sh reads it and writes the runtime manifest
# at container start.
#
# Security invariant: this Feature writes no credentials. Key auth comes only
# from the shared authorized_keys file.

PROJECT_NAME="${PROJECTNAME:-}"
USERNAME="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"
FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_PORT=2222
REMOTE_WORKSPACE_PATH="/workspace"
PAPERCLIP_ROOT="/opt/paperclip"
PAPERCLIP_SHARED_DIR="${PAPERCLIP_ROOT}/shared"
PAPERCLIP_MCP_CONFIG="${PAPERCLIP_SHARED_DIR}/mcp-extra.json"
PAPERCLIP_ENV_FILE="${PAPERCLIP_SHARED_DIR}/paperclip.env"
PAPERCLIP_NETWORK="paperclip-net"
PAPERCLIP_AGENT_DIR="/etc/paperclip-agent"
PAPERCLIP_USER_FILE="${PAPERCLIP_AGENT_DIR}/user"
PAPERCLIP_PROJECT_FILE="${PAPERCLIP_AGENT_DIR}/project-name"
RUNTIME_DIR="/usr/local/share/paperclip-agent"
PROFILE_SCRIPT="/etc/profile.d/paperclip-agent.sh"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/99-paperclip-agent.conf"
SSHD_BIN="/usr/sbin/sshd"
SSHD_BLOCK_BEGIN="# >>> paperclip-agent (managed) >>>"
SSHD_BLOCK_END="# <<< paperclip-agent (managed) <<<"
# Directives another config file could use to weaken key-only SSH or make the
# container unreachable. sshd takes the first value for most of these, and
# ListenAddress is additive, so files read before ours must not set them.
SSHD_CONFLICT_PATTERN='^[[:space:]]*(Port|ListenAddress|AddressFamily|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|AuthenticationMethods|PubkeyAcceptedAlgorithms|PubkeyAcceptedKeyTypes|PermitRootLogin|MaxAuthTries|PermitUserEnvironment|UsePAM|AuthorizedKeysFile|AllowUsers|AllowGroups|DenyUsers|DenyGroups)[[:space:]]+'

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

# Lowercase, collapse non-alphanumerics to hyphens, trim, and cap at 63 for the
# Docker network alias.
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-63 | sed -e 's/-$//'
}

# --- remote user -------------------------------------------------------------

if command -v getent >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6 || true)"
else
  USER_HOME="$(awk -F: -v u="$USERNAME" '$1 == u { print $6; exit }' /etc/passwd)"
fi

if [ -z "$USER_HOME" ]; then
  die "remote user '${USERNAME}' does not exist in this image.
       The claude-code and together-link Features install as this user, and
       Paperclip connects as this user, so it must already exist. Set
       remoteUser to a user that exists."
fi

mkdir -p "$PAPERCLIP_ROOT"
chmod 0755 "$PAPERCLIP_ROOT"

# --- sshd (always installed) -------------------------------------------------

command -v apt-get >/dev/null 2>&1 ||
  die "this Feature supports Debian/Ubuntu images with apt-get only; '${USERNAME}' exists but apt-get does not."

export DEBIAN_FRONTEND=noninteractive
echo "Installing openssh-server..."
apt-get update -y
packages=(openssh-server)
# `ss` is used by the doctor; install it only when the image lacks it.
command -v ss >/dev/null 2>&1 || packages+=(iproute2)
apt-get install -y --no-install-recommends "${packages[@]}"

mkdir -p /run/sshd
chmod 0755 /run/sshd

# Use the image's default host keys. The control plane connects with
# strictHostKeyChecking: false on the local network, so there is no pinned
# host key and no state volume.
ssh-keygen -A

[ -f "$SSHD_CONFIG" ] ||
  die "sshd was installed but ${SSHD_CONFIG} is missing; the image is not a standard OpenSSH package."

# sshd uses the first value it obtains for most keywords, and ListenAddress is
# additive. A stock image or another Feature can therefore leave a drop-in that
# re-enables passwords, blocks our user, or binds only to loopback. Comment
# those directives out in every file that is read before ours.
neutralize_directives() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -Eq "$SSHD_CONFLICT_PATTERN" "$file" || return 0

  awk -v pattern="$SSHD_CONFLICT_PATTERN" '
    $0 ~ pattern {
      print "# disabled by paperclip-agent: " $0
      next
    }
    { print }
  ' "$file" >"${file}.paperclip-tmp"
  mv -f "${file}.paperclip-tmp" "$file"
  chmod 0644 "$file"
}

sshd_settings="Port ${SSH_PORT}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 20"
if [ "$USERNAME" != "root" ]; then
  sshd_settings="${sshd_settings}
AllowUsers ${USERNAME}"
fi
sshd_settings="${sshd_settings}
AuthorizedKeysFile .ssh/authorized_keys
UsePAM yes
PermitUserEnvironment no"

if grep -Eq '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_CONFIG"; then
  mkdir -p "$SSHD_DROPIN_DIR"
  # Drop-ins sort before 99-paperclip-agent.conf, so theirs would win.
  for other in "$SSHD_DROPIN_DIR"/*.conf; do
    [ -e "$other" ] || continue
    [ "$other" = "$SSHD_DROPIN" ] && continue
    if grep -Eq "$SSHD_CONFLICT_PATTERN" "$other"; then
      warn "disabling conflicting sshd directives in ${other}; paperclip-agent owns SSH auth and the port."
      neutralize_directives "$other"
    fi
  done

  # The Include is normally at the top of sshd_config, so the drop-in wins
  # over the main file. Neutralize conflicts there too, for images that put
  # the Include lower down.
  neutralize_directives "$SSHD_CONFIG"

  cat >"$SSHD_DROPIN" <<EOF
# Managed by the paperclip-agent devcontainer Feature.
# Key-only SSH: no passwords, no root login, no user environment.
${sshd_settings}
EOF
  chmod 0644 "$SSHD_DROPIN"
else
  # No Include support: append a managed block and make sure no earlier
  # directive wins. A marker-delimited block makes rebuilds idempotent.
  neutralize_directives "$SSHD_CONFIG"
  if [ -f "$SSHD_CONFIG" ] && grep -qF "$SSHD_BLOCK_BEGIN" "$SSHD_CONFIG"; then
    awk -v b="$SSHD_BLOCK_BEGIN" -v e="$SSHD_BLOCK_END" '
      $0 == b { inblock = 1; next }
      $0 == e { inblock = 0; next }
      !inblock { print }
    ' "$SSHD_CONFIG" >"${SSHD_CONFIG}.paperclip-tmp"
    mv -f "${SSHD_CONFIG}.paperclip-tmp" "$SSHD_CONFIG"
  fi
  {
    printf '%s\n' "$SSHD_BLOCK_BEGIN"
    printf '%s\n' "$sshd_settings"
    printf '%s\n' "$SSHD_BLOCK_END"
  } >>"$SSHD_CONFIG"
  chmod 0644 "$SSHD_CONFIG"
fi

SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
[ -n "$SSHD_BIN" ] || SSHD_BIN="/usr/sbin/sshd"
if ! "$SSHD_BIN" -t -f "$SSHD_CONFIG"; then
  die "sshd rejected the generated configuration. Run '${SSHD_BIN} -t -f ${SSHD_CONFIG}' in the built image for details."
fi

echo "sshd configured on port ${SSH_PORT} for ${USERNAME}."

# --- runtime inputs ----------------------------------------------------------

# Runtime scripts cannot see the Feature's install-time environment variables.
# Persist the two values they need: the resolved username and the optional
# project-name override. The start script derives everything else.
mkdir -p "$PAPERCLIP_AGENT_DIR"
chmod 0755 "$PAPERCLIP_AGENT_DIR"
printf '%s\n' "$USERNAME" >"$PAPERCLIP_USER_FILE"
chmod 0644 "$PAPERCLIP_USER_FILE"
printf '%s\n' "$PROJECT_NAME" >"$PAPERCLIP_PROJECT_FILE"
chmod 0644 "$PAPERCLIP_PROJECT_FILE"

# --- locate the agent CLIs for the SSH PATH ----------------------------------

detect_claude() {
  local candidate
  candidate="$(command -v claude 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in \
    /opt/claude-code/bin/claude \
    /usr/local/share/nvm/current/bin/claude \
    "${USER_HOME}/.local/bin/claude"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if command -v npm >/dev/null 2>&1; then
    candidate="$(npm prefix -g 2>/dev/null || true)/bin/claude"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}

detect_node_dir() {
  local candidate dir
  candidate="$(command -v node 2>/dev/null || true)"
  if [ -n "$candidate" ]; then
    dirname "$candidate"
    return 0
  fi
  for dir in \
    "$(dirname "$CLAUDE_BIN")" \
    /usr/local/share/nvm/current/bin \
    /opt/claude-code/node/bin \
    "${USER_HOME}/.bun/bin"; do
    if [ -x "${dir}/node" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  if command -v npm >/dev/null 2>&1; then
    dir="$(npm prefix -g 2>/dev/null || true)/bin"
    if [ -x "${dir}/node" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  fi
  return 1
}

detect_togetherlink() {
  local candidate
  for candidate in \
    /opt/together-link/bin/togetherlink \
    "${USER_HOME}/.togetherlink/bin/togetherlink"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate="$(command -v togetherlink 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

CLAUDE_BIN="$(detect_claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  die "claude was not found after installing this Feature.
       This Feature depends on ghcr.io/aj-foster/devcontainer-features/claude-code:1.
       If your devcontainer CLI ignored dependsOn, add that Feature to
       devcontainer.json (and together-link) and rebuild."
fi
CLAUDE_DIR="$(dirname "$CLAUDE_BIN")"

TOGETHERLINK_BIN="$(detect_togetherlink || true)"
if [ -z "$TOGETHERLINK_BIN" ]; then
  die "togetherlink was not found after installing this Feature.
       This Feature depends on ghcr.io/aj-foster/devcontainer-features/together-link:1.
       If your devcontainer CLI ignored dependsOn, add that Feature to
       devcontainer.json and rebuild."
fi

NODE_DIR="$(detect_node_dir || true)"
if [ -z "$NODE_DIR" ]; then
  warn "could not find a Node.js directory; the SSH PATH may not resolve node for npm-installed Claude Code."
fi

# --- PATH contract for non-interactive SSH -----------------------------------

# Paperclip's SSH runner sources /etc/profile before running its command. This
# profile.d file is the contract that makes claude/togetherlink resolvable over
# a non-interactive, non-login SSH command.
profile_path=""
add_profile_dir() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  case ":${profile_path}:" in
    *":${dir}:"*) return 0 ;;
  esac
  profile_path="${profile_path:+${profile_path}:}${dir}"
}
add_profile_dir "/opt/claude-code/bin"
add_profile_dir "/opt/claude-code/node/bin"
add_profile_dir "/opt/together-link/bin"
# ${HOME} stays literal so the file works for any SSH user.
add_profile_dir '${HOME}/.bun/bin'
add_profile_dir "$CLAUDE_DIR"
add_profile_dir "$NODE_DIR"
add_profile_dir "$(dirname "$TOGETHERLINK_BIN")"

mkdir -p "$(dirname "$PROFILE_SCRIPT")"
cat >"$PROFILE_SCRIPT" <<EOF
# Managed by the paperclip-agent devcontainer Feature.
# Paperclip's SSH runner sources /etc/profile (and therefore this file) before
# running a command. Do not add credentials here: tclaude and the Paperclip
# adapter handle the Together API key.
export PATH="${profile_path}:\$PATH"
export PAPERCLIP_AGENT_MCP_CONFIG="${PAPERCLIP_MCP_CONFIG}"
export PAPERCLIP_AGENT_REMOTE_WORKSPACE="${REMOTE_WORKSPACE_PATH}"

# Non-secret fleet settings (Paperclip API URL, company ID). Read by every
# shell in every target; never put tokens in this file.
if [ -f "${PAPERCLIP_ENV_FILE}" ]; then
  set -a
  . "${PAPERCLIP_ENV_FILE}"
  set +a
fi
EOF
chmod 0644 "$PROFILE_SCRIPT"

# --- runtime scripts ---------------------------------------------------------

mkdir -p "$RUNTIME_DIR"
mkdir -p /usr/local/bin
install -m 0755 "${FEATURE_DIR}/entrypoint.sh" "${RUNTIME_DIR}/entrypoint.sh"
install -m 0755 "${FEATURE_DIR}/doctor.sh" /usr/local/bin/paperclip-agent-doctor

PROJECT_SLUG=""
if [ -n "$PROJECT_NAME" ]; then
  PROJECT_SLUG="$(slugify "$PROJECT_NAME")"
  [ -n "$PROJECT_SLUG" ] || PROJECT_SLUG="agent"
fi

echo "paperclip-agent ready:"
echo "  ssh:       ${USERNAME}@${PROJECT_SLUG:-<derived at start>}:${SSH_PORT} on ${PAPERCLIP_NETWORK}"
echo "  workspace: ${REMOTE_WORKSPACE_PATH}"
echo "  shared:    ${PAPERCLIP_SHARED_DIR} (host ~/.paperclip)"
echo "  manifest:  ${PAPERCLIP_ROOT}/environment.json (written at container start)"
echo "Run 'paperclip-agent-doctor --json' inside the container to verify."
