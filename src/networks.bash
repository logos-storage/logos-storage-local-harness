#!/usr/bin/env bash
# Manages port ranges for named networks.

declare -gA _net_sizes=()
declare -gA _net_port_bases=()
_net_next_port=8000

# Names exclude ':' so network:port keys are unambiguous.
net_declare() {
  local network="$1" size="$2"
  if [[ ! "$network" =~ ^[a-zA-Z0-9_-]+$ || ! "$size" =~ ^[1-9][0-9]{0,4}$ ]] ||
    (( size > 57536 )); then
    printf 'Error: invalid network name or size\n' >&2
    return 1
  fi

  if [[ -n "${_net_sizes[$network]:-}" && "${_net_sizes[$network]}" != "$size" ]]; then
    printf 'Error: network %s already has a different size\n' "$network" >&2
    return 1
  fi
  _net_sizes[$network]="$size"
}

net_size() {
  local network="$1"
  if [[ -z "$network" || -z "${_net_sizes[$network]:-}" ]]; then
    printf 'Error: unknown network %s\n' "$network" >&2
    return 1
  fi
  printf '%s\n' "${_net_sizes[$network]}"
}

net_decl_port() {
  local network="$1" port="$2" size key="$1:$2"
  size=$(net_size "$network") || return 1
  if [[ ! "$port" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    printf 'Error: invalid port name %s\n' "$port" >&2
    return 1
  fi
  [[ -n "${_net_port_bases[$key]:-}" ]] && return 0

  if (( _net_next_port + size > 65536 )); then
    printf 'Error: no port range available for %s\n' "$key" >&2
    return 1
  fi
  _net_port_bases[$key]="$_net_next_port"
  _net_next_port=$((_net_next_port + size))
}

net_decl_ports() {
  local network="$1" port
  shift
  for port in "$@"; do
    net_decl_port "$network" "$port" || return 1
  done
}

net_base_port() {
  local key="$1:$2"
  if [[ -z "${_net_port_bases[$key]:-}" ]]; then
    printf 'Error: unknown port range %s\n' "$key" >&2
    return 1
  fi
  printf '%s\n' "${_net_port_bases[$key]}"
}

net_port() {
  local network="$1" port="$2" node="$3" size base
  size=$(net_size "$network") || return 1
  base=$(net_base_port "$network" "$port") || return 1
  if [[ ! "$node" =~ ^(0|[1-9][0-9]{0,4})$ ]] || (( node >= size )); then
    printf 'Error: invalid node index %s for network %s\n' "$node" "$network" >&2
    return 1
  fi
  printf '%s\n' "$((base + node))"
}

net_clear() {
  _net_sizes=()
  _net_port_bases=()
  _net_next_port=8000
}
