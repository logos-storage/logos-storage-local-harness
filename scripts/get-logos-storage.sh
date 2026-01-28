#!/usr/bin/env bash
set -euo pipefail

# Fetches the latest Logos Storage binary from GitHub releases.
#
# Usage: ./scripts/get0-logos-storage.sh [output_dir]
#   output_dir: Directory to place the binary (default: ./bin)

readonly API_BASE_URL="https://api.github.com/repos/logos-storage/logos-storage-nim"
readonly DOWNLOAD_BASE_URL="https://github.com/logos-storage/logos-storage-nim/releases/download"
readonly BINARY_NAME="storage"

output_dir="${1:-./}"

detect_platform() {
  local os arch

  case "$(uname -s)" in
    Linux*)  os="linux" ;;
    Darwin*) os="darwin" ;;
    *)       echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)            echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  echo "${os}-${arch}"
}

fetch_latest_version() {
  curl -sL "${API_BASE_URL}/releases/latest" |
    grep -oE '"tag_name": "[^"]+"' |
    head -1 |
    sed 's/"tag_name": "//;s/"$//'
}

main() {
  local platform version download_url tmp_dir executable_name

  platform=$(detect_platform)
  echo "Detected platform: ${platform}"

  echo "Fetching latest release info..."
  version=$(fetch_latest_version)

  if [[ -z "$version" ]]; then
    echo "Error: Could not determine latest version" >&2
    exit 1
  fi

  echo "Latest version: ${version}"

  executable_name="logos-storage-${platform}-${version}"
  download_url="${DOWNLOAD_BASE_URL}/${version}/${executable_name}.tar.gz"

  echo "Downloading from: ${download_url}"

  tmp_dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_dir}'" EXIT

  curl -sL "$download_url" -o "${tmp_dir}/archive.tar.gz"

  echo "Extracting..."
  echo "tar -xzf ${tmp_dir}/archive.tar.gz -C ${tmp_dir}"
  tar -xzf "${tmp_dir}/archive.tar.gz" -C "$tmp_dir"

  mkdir -p "$output_dir"

  mv "${tmp_dir}/${executable_name}" "${output_dir}/${BINARY_NAME}"
  chmod +x "${output_dir}/${BINARY_NAME}"

  echo "Logos Storage binary installed to: ${output_dir}/${BINARY_NAME}"
  "${output_dir}/${BINARY_NAME}" --version || true
}

main "$@"
