#!/usr/bin/env bash
set -o pipefail

if ! command -v sha1sum > /dev/null; then
  echoerr "Error: sha1sum is required for computing file hashes"
  exit 1
fi

echoerr() {
  echo "$@" >&2
}

shift_arr () {
  local -n arr_ref="$1"
  local shifts="${2:-1}"
  arr_ref=("${arr_ref[@]:shifts}")
}

sha1() {
  sha1sum "$1" | cut -d ' ' -f 1 || return 1
}

require_binary() {
  local -n var="$1"
  local label="$2" env_var="$3"
  local path="${!env_var:-}"

  if [ -z "$path" ]; then
    echoerr "Error: ${label} binary path not set. Set ${env_var} to point to a compiled ${label}."
    return 1
  fi

  if [ ! -x "$path" ]; then
    echoerr "Error: ${label} binary at ${path} is not executable."
    return 1
  fi

  var="$path"
}

await() {
  local timeout="${1:-30}"
  shift
  await_poll "${timeout}" 0.1 "$@"
}

await_poll() {
  local timeout="$1" poll_interval="$2"
  shift 2
  local cmd=("$@")
  local start=$SECONDS

  while true; do
    echoerr "Awaiting for predicate to be true: ${cmd[*]}"
    if "${cmd[@]}"; then
      return 0
    fi
    if ((SECONDS - start >= timeout)); then
      return 1
    fi
    sleep "${poll_interval}"
  done
}

fail() {
  local msg="$1"
  echoerr "Error: ${msg}"
  exit 1
}