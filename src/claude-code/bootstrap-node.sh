#!/usr/bin/env bash
# Isolated Node.js + npm for Claude Code when the image has neither.
# Installs under /opt/claude-code/node and does not put node/npm on PATH.

CLAUDE_CODE_ROOT="${CLAUDE_CODE_ROOT:-/opt/claude-code}"
CLAUDE_CODE_NODE_ROOT="${CLAUDE_CODE_NODE_ROOT:-${CLAUDE_CODE_ROOT}/node}"
CLAUDE_CODE_BIN_DIR="${CLAUDE_CODE_BIN_DIR:-${CLAUDE_CODE_ROOT}/bin}"

claude_code_download() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null; then
    wget -qO "$dest" "$url"
  else
    echo "ERROR: curl or wget is required to bootstrap Node.js." >&2
    echo "Install one of those, or add \"ghcr.io/devcontainers/features/node:1\" so npm is already present." >&2
    return 1
  fi
}

claude_code_node_arch() {
  case "$(uname -m)" in
    x86_64) echo x64 ;;
    aarch64 | arm64) echo arm64 ;;
    *)
      echo "ERROR: unsupported architecture '$(uname -m)' for isolated Node.js bootstrap." >&2
      echo "Add \"ghcr.io/devcontainers/features/node:1\" instead." >&2
      return 1
      ;;
  esac
}

claude_code_is_musl() {
  if [ -f /etc/alpine-release ]; then
    return 0
  fi
  if ldd /bin/sh 2>/dev/null | grep -qi musl; then
    return 0
  fi
  return 1
}

claude_code_latest_lts() {
  local tab="$1"
  # Download the full index first: piping into awk would SIGPIPE curl under pipefail.
  claude_code_download "https://nodejs.org/dist/index.tab" "$tab"
  awk -F '\t' '
    NR == 1 {
      for (i = 1; i <= NF; i++) if ($i == "lts") col = i
      next
    }
    col && $col != "-" && $col != "" {
      print $1
      exit
    }
  ' "$tab"
}

claude_code_verify_sha256() {
  local file="$1"
  local sums="$2"
  local name expected actual
  name="$(basename "$file")"
  expected="$(awk -v name="$name" '$2 == name { print $1; exit }' "$sums")"
  if [ -z "$expected" ]; then
    echo "ERROR: no SHA256 listed for ${name}." >&2
    return 1
  fi
  actual="$(sha256sum "$file" | awk '{ print $1 }')"
  if [ "$expected" != "$actual" ]; then
    echo "ERROR: SHA256 mismatch for ${name}." >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    return 1
  fi
}

# Download current Node.js LTS into CLAUDE_CODE_NODE_ROOT and chown it to $1.
claude_code_bootstrap_node() {
  local username="$1"
  local arch version tmp filename url base group

  arch="$(claude_code_node_arch)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  version="$(claude_code_latest_lts "${tmp}/index.tab")"
  if [ -z "$version" ]; then
    echo "ERROR: could not resolve the current Node.js LTS version." >&2
    return 1
  fi

  if claude_code_is_musl; then
    filename="node-${version}-linux-${arch}-musl.tar.gz"
    base="https://unofficial-builds.nodejs.org/download/release/${version}"
  else
    filename="node-${version}-linux-${arch}.tar.gz"
    base="https://nodejs.org/dist/${version}"
  fi
  url="${base}/${filename}"

  echo "Downloading isolated Node.js ${version} (${filename})..."
  claude_code_download "$url" "${tmp}/${filename}"
  claude_code_download "${base}/SHASUMS256.txt" "${tmp}/SHASUMS256.txt"
  claude_code_verify_sha256 "${tmp}/${filename}" "${tmp}/SHASUMS256.txt"

  rm -rf "$CLAUDE_CODE_NODE_ROOT"
  mkdir -p "$CLAUDE_CODE_NODE_ROOT"
  tar -xzf "${tmp}/${filename}" -C "$CLAUDE_CODE_NODE_ROOT" --strip-components=1

  if ! [ -x "${CLAUDE_CODE_NODE_ROOT}/bin/npm" ]; then
    echo "ERROR: isolated Node.js extract is missing bin/npm." >&2
    return 1
  fi

  # Marker so a later rebuild that already has npm can delete this tree.
  touch "${CLAUDE_CODE_NODE_ROOT}/.bootstrapped-by-claude-code"
  group="$(id -gn "$username")"
  chown -R "${username}:${group}" "$CLAUDE_CODE_NODE_ROOT"

  echo "Isolated Node.js ${version} installed at ${CLAUDE_CODE_NODE_ROOT} (not on PATH)."
}

# Public claude entrypoint that puts isolated node/npm on PATH for this process only.
claude_code_install_wrapper() {
  mkdir -p "$CLAUDE_CODE_BIN_DIR"
  cat >"${CLAUDE_CODE_BIN_DIR}/claude" <<EOF
#!/bin/sh
export PATH="${CLAUDE_CODE_NODE_ROOT}/bin:\$PATH"
exec "${CLAUDE_CODE_NODE_ROOT}/bin/claude" "\$@"
EOF
  chmod 755 "${CLAUDE_CODE_BIN_DIR}/claude"
}
