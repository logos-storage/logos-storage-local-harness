#!/usr/bin/env bash
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

apply_conf() {
  local cmd_arg="$1" conf_file="$2" conf_var="${3:-config}"
  if [ "$cmd_arg" != "use_conf" ]; then
    return 1
  fi
  if [ ! -f "$conf_file" ]; then
    fail "Error: configuration file not found: $conf_file"
  fi
  echoerr "Sourcing configuration file: $conf_file"
  # shellcheck disable=SC1090
  source "$conf_file" || fail "Error sourcing configuration file: $conf_file"
  _do_apply_conf "${conf_var}" || fail "Error applying configuration from file: $conf_file"
}

_do_apply_conf() {
  local -n _apply_conf_values="$1"
  local _apply_conf_key _apply_conf_words
  local -a _apply_conf_items

  if [ "${#_apply_conf_values[@]}" -eq 0 ]; then
    echoerr "Error: configuration ${1} variable is empty or not an associative array"
    return 1
  fi

  for _apply_conf_key in "${!_apply_conf_values[@]}"; do
    if [[ "$_apply_conf_key" == *_arr ]]; then
      # Strip the suffix and split on spaces, preserving literal shell characters.
      IFS=' ' read -r -d '' -a _apply_conf_items < <(printf '%s\0' "${_apply_conf_values[$_apply_conf_key]}")
      _apply_conf_words=''
      if [ "${#_apply_conf_items[@]}" -gt 0 ]; then
        printf -v _apply_conf_words '%q ' "${_apply_conf_items[@]}"
      fi
      declare -ga -- "${_apply_conf_key%_arr}=(${_apply_conf_words})" || return 1
    else
      declare -g -- "${_apply_conf_key}=${_apply_conf_values[$_apply_conf_key]}" || return 1
    fi
  done
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

  #shellcheck disable=SC2034
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
