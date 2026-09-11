#!/usr/bin/env bash
set -o pipefail

LIB_SRC=${LIB_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# shellcheck source=./src/utils.bash
source "${LIB_SRC}/utils.bash"
# shellcheck source=./src/procmon.bash
source "${LIB_SRC}/procmon.bash"

# Logos Storage binary
if [ -z "${STORAGE_BINARY}" ]; then
  _cdx_binary="$(command -v storage)" || true
else
  _cdx_binary="${STORAGE_BINARY}"
fi

if [ ! -f "${_cdx_binary}" ]; then
  echoerr "Error: no valid Logos Storage binary found."\
 "Set STORAGE_BINARY to point to a valid Logos Storage binary."
  exit 1
fi

echoerr "[storage] Using binary at ${_cdx_binary}"

# Mix pool tool binary (only required when an experiment turns Mix on)
if [ -n "${MIX_POOL_BINARY:-}" ]; then
  _cdx_mix_pool_binary="${MIX_POOL_BINARY}"
fi

if [ -n "${MIX_RELAY_DHT_BINARY:-}" ]; then
  _cdx_mix_relay_dht_binary="${MIX_RELAY_DHT_BINARY}"
fi

_cdx_mix_min_pool=4

# Tracked PIDs for relay processes (separate from storage node PIDs)
declare -A _cdx_mix_relay_pids

cdx_require_binary() {
  local path="$1" label="$2" env_name="$3"
  if [ -z "$path" ] || [ ! -x "$path" ]; then
    echoerr "Error: no valid ${label} binary found." \
            "Set ${env_name} to point to a compiled ${label}."
    return 1
  fi
}

cdx_require_mix_pool_binary() {
  cdx_require_binary \
    "${_cdx_mix_pool_binary:-}" "mix_pool" "MIX_POOL_BINARY"
}

cdx_require_mix_relay_dht_binary() {
  cdx_require_binary \
    "${_cdx_mix_relay_dht_binary:-}" "mix_relay_dht" "MIX_RELAY_DHT_BINARY"
}

cdx_generate_mix_pool() {
  local pool_size="$1" pool_dir="$2"
  cdx_require_mix_pool_binary || return 1
  rm -rf "${pool_dir}"
  mkdir -p "${pool_dir}"
  "${_cdx_mix_pool_binary}" init \
    --pool="${pool_dir}/pool.json" \
    --count="${pool_size}" \
    --outdir="${pool_dir}/relays" >&2 || return 1
}

cdx_launch_relay() {
  local relay_index="$1" bootstrap_spr="${2:-}" base_port log_file data_dir cmd backend binary
  local relay_api_port relay_metrics_port quoted_log_file
  local -a cmd_args
  backend="${CDX_MIX_RELAY_BACKEND:-standalone}"

  if [ -z "${CDX_MIX_POOL_DIR:-}" ]; then
    echoerr "Error: cdx_launch_relay requires CDX_MIX_POOL_DIR"
    return 1
  fi

  _cdx_init_global_outputs || return 1

  base_port="${CDX_RELAY_BASE_PORT:-4242}"
  data_dir="${CDX_MIX_POOL_DIR}/relays/relay_${relay_index}"

  cmd_args=(
    "--data-dir=${data_dir}"
    "--listen-ip=127.0.0.1"
    "--listen-port=$((base_port + relay_index))"
    "--log-level=${_cdx_relay_log_level}"
  )

  case "${backend}" in
    standalone)
      cdx_require_mix_relay_dht_binary || return 1
      log_file="${_cdx_logs}/relay-${relay_index}.log"
      binary="${_cdx_mix_relay_dht_binary}"
      cmd_args+=("--no-dht-proxy")
      ;;
    storage)
      log_file="${_cdx_logs}/storage-relay-${relay_index}.log"
      binary="${_cdx_binary}"
      relay_api_port=$((9080 + relay_index))
      relay_metrics_port=$((9290 + relay_index))
      cmd_args+=(
        "--nat=extip:127.0.0.1"
        "--api-port=${relay_api_port}"
        "--metrics-port=${relay_metrics_port}"
        "--no-bootstrap-node"
        "--mix-enabled"
        "--mix-pool=${CDX_MIX_POOL_DIR}/pool.json"
      )
      ;;
    mix_relay_dht)
      cdx_require_mix_relay_dht_binary || return 1
      log_file="${_cdx_logs}/relay-dht-${relay_index}.log"
      binary="${_cdx_mix_relay_dht_binary}"
      if [[ -n "${bootstrap_spr}" ]]; then
        cmd_args+=("--bootstrap-node=${bootstrap_spr}")
      fi
      ;;
    *)
      echoerr "Error: invalid CDX_MIX_RELAY_BACKEND='${backend}'" \
        "(use 'standalone', 'storage', or 'mix_relay_dht')"
      return 1
      ;;
  esac

  printf -v cmd '%q ' "${binary}" "${cmd_args[@]}"
  printf -v quoted_log_file '%q' "${log_file}"
  pm_async "bash" "-c" "exec ${cmd}&> ${quoted_log_file}" \
    -%- "mix-relay (${backend})" "${relay_index}"
  _cdx_mix_relay_pids[$relay_index]=$!

  # Relay has no HTTP endpoint to poll; brief sleep to let it bind the port.
  sleep 0.5
}

cdx_launch_relays() {
  local count="$1" bootstrap_spr="${2:-}" i backend
  backend="${CDX_MIX_RELAY_BACKEND:-standalone}"
  echoerr "Launching ${count} Mix relays (backend: ${backend})..."
  for i in $(seq 0 "$((count - 1))"); do
    cdx_launch_relay "$i" "${bootstrap_spr}" || return 1
  done
}

cdx_stop_relays() {
  local idx pid
  for idx in "${!_cdx_mix_relay_pids[@]}"; do
    pid="${_cdx_mix_relay_pids[$idx]}"
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
    fi
  done
  _cdx_mix_relay_pids=()
}

# Custom prefix for timing logs
_cdx_timing_prefix=""
# Log file where timings are aggregated
_cdx_timing_log="/dev/null"
# Base ports and timeouts
_cdx_base_api_port=8080
_cdx_base_metrics_port=8290
_cdx_node_start_timeout=30
_cdx_defaultopts=()
_cdx_log_level="INFO"
_cdx_relay_log_level="INFO"

echoerr "[storage] Node log level is ${_cdx_log_level}"
echoerr "[storage] Relay log level is ${_cdx_relay_log_level}"

# PID array for known Logos Storage node processes
# FIXME: right now only processes destroyed with cdx_destroy_node are removed from
#   this array.
declare -A _cdx_pids

_cdx_bootstrap_pid=""
_cdx_bootstrap_api_port=7080

cdx_set_outputs() {
  # Output folders
  _cdx_output="$1"
  # generated files
  _cdx_genfiles="${_cdx_output}/genfiles"
  # downloaded files, per node. File names are CIDs
  _cdx_downloads="${_cdx_output}/downloads"
  # SHA1 of uploaded files, per node. File names are CIDs
  _cdx_uploads="${_cdx_output}/uploads"
  # Logos Storage node logs, per node
  _cdx_logs="${_cdx_output}/logs"
  # Logos Storage data directories, per node
  _cdx_data="${_cdx_output}/data"
  # Partial timings, per operation per node
  _cdx_timing_partials="${_cdx_output}/timing"
}

_ensure_outputs_set() {
  if [ -z "${_cdx_output}" ]; then
    echoerr "Error: outputs not set"
    return 1
  fi
}

_cdx_api_port() {
  local node_index="$1"
  echo $((_cdx_base_api_port + node_index))
}

_cdx_metrics_port() {
  local node_index="$1"
  echo $((_cdx_base_metrics_port + node_index))
}

cdx_add_defaultopts() {
  _cdx_defaultopts+=("$@")
}

cdx_clear_defaultopts() {
  _cdx_defaultopts=()
}

cdx_set_log_level() {
  _cdx_log_level="$1"
}

cdx_set_relay_log_level() {
  _cdx_relay_log_level="$1"
}

cdx_cmdline() {
  local node_index spr opt cmd
  local -a opts=("$@")
  local -a cmd_args=(
    "${_cdx_binary}"
    "--nat=extip:127.0.0.1"
    "--listen-ip=127.0.0.1"
  )

  opts+=("${_cdx_defaultopts[@]}")

  node_index="${opts[0]}"
  shift_arr opts

  while [[ "${#opts[@]}" -gt 0 ]]; do
    opt="${opts[0]}"
    case "$opt" in
      --bootstrap-node)
        shift_arr opts
        spr="${opts[0]}"
        cmd_args+=("--bootstrap-node=${spr}")
        ;;
      --dht-mix-proxy)
        shift_arr opts
        cmd_args+=("--dht-mix-proxy=${opts[0]}")
        ;;
      --metrics)
        cmd_args+=(
          "--metrics"
          "--metrics-port=$(_cdx_metrics_port "$node_index")"
          "--metrics-address=0.0.0.0"
        )
        ;;
      --no-bootstrap-node)
        cmd_args+=("--no-bootstrap-node")
        ;;
      *)
        echoerr "Error: unknown option $opt"
        return 1
        ;;
    esac
    shift_arr opts
  done

  if [[ "$node_index" -gt 0 && -z "$spr" ]]; then
    echoerr "Error: SPR is required for node $node_index"
    return 1
  fi

  if [[ "${CDX_MIX_ENABLED:-}" == "true" ]]; then
    if [[ -z "${CDX_MIX_POOL_DIR:-}" ]]; then
      echoerr "Error: CDX_MIX_ENABLED requires CDX_MIX_POOL_DIR"
      return 1
    fi
    cmd_args+=(
      "--mix-enabled"
      "--mix-pool=${CDX_MIX_POOL_DIR}/pool.json"
    )
  fi

  cmd_args+=(
    "--data-dir=${_cdx_data}/storage-${node_index}"
    "--api-port=$(_cdx_api_port "$node_index")"
    "--log-level=${_cdx_log_level}"
  )

  printf -v cmd '%q ' "${cmd_args[@]}"
  printf '%s\n' "${cmd% }"
}

cdx_get_spr() {
  local node_index="$1" field="${2:-spr}" spr

  spr=$(curl --silent --fail "http://localhost:$(_cdx_api_port "$node_index")/api/storage/v1/debug/info" \
    | grep -oP '"'"$field"'"\s*:\s*"\K[^"]+')
  if [[ -z "$spr" ]]; then
    echoerr "Error: unable to get $field for node $node_index"
    return 1
  fi

  echo "${spr}"
}

cdx_launch_node() {
  local node_index="$1" storage_cmd log_file quoted_log_file

  _cdx_init_global_outputs || return 1
  _cdx_init_node_outputs "${node_index}" || return 1

  storage_cmd=$(cdx_cmdline "$@") || return 1
  log_file="${_cdx_logs}/storage-${node_index}.log"
  printf -v quoted_log_file '%q' "${log_file}"

  pm_async "bash" "-c" "exec ${storage_cmd} &> ${quoted_log_file}" \
    -%- "storage" "${node_index}"
  _cdx_pids[$node_index]=$!

  cdx_ensure_ready "$node_index"
}

cdx_launch_bootstrap() {
  local cmd data_dir quoted_log_file
  local -a cmd_args

  _cdx_init_global_outputs || return 1
  data_dir="${_cdx_data}/bootstrap"
  mkdir -p "${data_dir}" || return 1

  cmd_args=(
    "${_cdx_binary}"
    "--nat=extip:127.0.0.1"
    "--listen-ip=127.0.0.1"
    "--no-bootstrap-node"
    "--data-dir=${data_dir}"
    "--api-port=${_cdx_bootstrap_api_port}"
    "--log-level=${_cdx_log_level}"
  )

  printf -v cmd '%q ' "${cmd_args[@]}"
  printf -v quoted_log_file '%q' "${_cdx_logs}/bootstrap.log"
  pm_async "bash" "-c" "exec ${cmd}&> ${quoted_log_file}" \
    -%- "storage" "bootstrap"
  _cdx_bootstrap_pid=$!

  local start="${SECONDS}"
  while true; do
    if cdx_get_bootstrap_spr 2> /dev/null > /dev/null; then
      echoerr "Bootstrap node is ready."
      return 0
    fi
    if (( SECONDS - start > _cdx_node_start_timeout )); then
      echoerr "Bootstrap node did not start within ${_cdx_node_start_timeout} seconds."
      return 1
    fi
    sleep 0.2
  done
}

cdx_get_bootstrap_spr() {
  local spr
  spr=$(curl --silent --fail \
    "http://localhost:${_cdx_bootstrap_api_port}/api/storage/v1/debug/info" \
    | grep -oP '"spr"\s*:\s*"\K[^"]+')
  if [[ -z "$spr" ]]; then
    echoerr "Error: unable to get spr for bootstrap node"
    return 1
  fi
  echo "${spr}"
}

cdx_stop_bootstrap() {
  if [[ -n "${_cdx_bootstrap_pid}" ]] && kill -0 "${_cdx_bootstrap_pid}" 2>/dev/null; then
    kill -TERM "${_cdx_bootstrap_pid}" 2>/dev/null
  fi
  _cdx_bootstrap_pid=""
}

cdx_launch_network() {
  local node_count="$1" bootstrap_spr="${2:-}"
  local mix_node_spr extra_args=()
  if [[ "$node_count" -lt 2 ]]; then
    echoerr "Error: a Logos Storage network needs at least 2 nodes"
    return 1
  fi
  if [[ -z "${bootstrap_spr}" ]]; then
    echoerr "Error: cdx_launch_network requires a bootstrap SPR (2nd arg)"
    return 1
  fi

  cdx_launch_node 0 --bootstrap-node "${bootstrap_spr}" || return 1

  if [[ "${CDX_MIX_ENABLED:-}" == "true" ]]; then
    if [[ "${CDX_MIX_RELAY_BACKEND:-standalone}" == "mix_relay_dht" ]]; then
      local relay_count="${#_cdx_mix_relay_pids[@]}" i mix_node_spr_file tries
      for i in $(seq 0 "$((relay_count - 1))"); do
        mix_node_spr_file="${CDX_MIX_POOL_DIR}/relays/relay_${i}/mix_node.spr"
        tries=0
        while [[ ! -s "${mix_node_spr_file}" && $tries -lt 60 ]]; do
          sleep 0.2
          tries=$((tries + 1))
        done
        if [[ ! -s "${mix_node_spr_file}" ]]; then
          echoerr "Error: mix_relay_dht ${i} did not write ${mix_node_spr_file}"
          return 1
        fi
        mix_node_spr=$(cat "${mix_node_spr_file}")
        extra_args+=("--dht-mix-proxy" "$mix_node_spr")
      done
    else
      mix_node_spr=$(cdx_get_spr 0 providerRecord) || return 1
      extra_args+=("--dht-mix-proxy" "$mix_node_spr")
    fi
  fi

  for i in $(seq 1 "$((node_count - 1))"); do
    cdx_launch_node "$i" "--bootstrap-node" "$bootstrap_spr" "${extra_args[@]}" || return 1
  done
  return 0
}

cdx_pid() {
  local node_index="$1"
  echo "${_cdx_pids[$node_index]}"
}

cdx_destroy_node() {
  local node_index="$1" wipe_data="${2:-false}" pid
  pid="$(cdx_pid "$node_index")"
  if [ -z "$pid" ]; then
    echoerr "Error: no process ID for node $node_index"
    return 1
  fi

  # Prevents the whole process group from dying.
  pm_stop_tracking "$pid"
  pm_kill_rec "$pid"
  await "$pid" || return 1

  unset "_cdx_pids[$node_index]"

  if [ "$wipe_data" = true ]; then
    rm -rf "${_cdx_data}/storage-${node_index}"
    rm -rf "${_cdx_logs}/storage-${node_index}.log"
  fi
}

cdx_ensure_ready() {
  local node_index="$1" timeout=${2:-$_cdx_node_start_timeout} start="${SECONDS}"
  echoerr "Waiting ${timeout} seconds for node ${node_index} to be ready."
  while true; do
    if cdx_get_spr "$node_index" 2> /dev/null; then
      echoerr "Logos Storage node $node_index is ready."
      return 0
    fi

    if (( SECONDS - start > timeout )); then
      echoerr "Logos Storage node $node_index did not start within ${timeout} seconds."
      return 1
    fi

    sleep 0.2
  done
}

_cdx_init_node_outputs() {
  local node_index="$1"
  _ensure_outputs_set || return 1

  mkdir -p "${_cdx_data}/storage-${node_index}" || return 1
  mkdir -p "${_cdx_downloads}/storage-${node_index}" || return 1
  mkdir -p "${_cdx_uploads}/storage-${node_index}" || return 1
}

# XXX: output initialization is a bit of a pain. Right now it's
#   being piggybacked on cdx_launch_node and cdx_log_timings_start
#   so we don't have to add extra initialization calls.
_cdx_init_global_outputs() {
  _ensure_outputs_set || return 1

  mkdir -p "${_cdx_logs}" || return 1
  mkdir -p "${_cdx_genfiles}" || return 1
  mkdir -p "${_cdx_timing_partials}" || return 1
}

cdx_generate_file() {
  local size_mb="${1}" filename
  filename="${_cdx_genfiles}/file-$(date +%s).bin"

  echoerr "Generating file ${filename} of size ${size_mb}MB"
  dd if=/dev/urandom of="${filename}" bs=1M count="${size_mb}" || return 1
  echo "${filename}"
}

cdx_upload_file() {
  local node_index="$1" filename="$2" content_sha1 cid

  content_sha1=$(sha1 "$filename") || return 1

  echoerr "Uploading file ${filename} to node ${node_index}"

  cid=$(curl --silent --fail\
    -XPOST "http://localhost:$(_cdx_api_port "$node_index")/api/storage/v1/data"\
    -T "${filename}") || return 1

  echoerr "Upload SHA-1 is ${content_sha1}"

  echo "${content_sha1}" > "${_cdx_uploads}/storage-${node_index}/${cid}.sha1"
  echo "${cid}"
}

cdx_download_file() {
  local node_index="$1" cid="$2" timestamp
  timestamp="$(date +%s)" || return 1

  TIMEFORMAT="${_cdx_timing_prefix}download,${node_index},${cid},%E,%U,%S"
  # Note that timing partial filenames are constructed so that lexicographic sorting
  # puts the most recent entries first, while at the same time breaking ties arbitrarily
  # for entries that happen within the same second.
  { time curl --silent --fail\
    -XGET "http://localhost:$(_cdx_api_port "$node_index")/api/storage/v1/data/$cid/network/stream"\
    -o "${_cdx_downloads}/storage-${node_index}/$cid" ; } 2> \
    "${_cdx_timing_partials}/storage-${node_index}-${timestamp}-${RANDOM}.csv"
}

cdx_download_file_async() {
  pm_async cdx_download_file "$@" -%- "download"
}

cdx_upload_sha1() {
  local node_index="$1" cid="$2"
  cat "${_cdx_uploads}/storage-${node_index}/${cid}.sha1" || return 1
}

cdx_download_sha1() {
  local node_index="$1" cid="$2"
  sha1 "${_cdx_downloads}/storage-${node_index}/$cid" || return 1
}

cdx_check_download() {
  local upload_node="$1"\
    download_node="$2"\
    cid="$3"\
    upload_sha1\
    download_sha1

  upload_sha1=$(cdx_upload_sha1 "$upload_node" "$cid")
  download_sha1=$(cdx_download_sha1 "$download_node" "$cid")

  if [ "$upload_sha1" != "$download_sha1" ]; then
    # shellcheck disable=SC2140
    echoerr "Download SHA-1 at node $download_node ($download_sha1) does not"\
" match upload SHA-1 at node $upload_node ($upload_sha1)"
    return 1
  fi
  return 0
}

cdx_log_timings_start() {
  _cdx_init_global_outputs || return 1

  local log_file="$1" prefix="$2"

  touch "$log_file" || return 1

  _cdx_timing_log="$log_file"
  if [[ ! "$prefix" =~ ',$' ]]; then
    prefix="$prefix,"
  fi
  _cdx_timing_prefix="$prefix"
}

cdx_flush_partial_timings() {
  for file in "${_cdx_timing_partials}"/*; do
    cat "$file" >> "${_cdx_timing_log}" || return 1
    rm "$file"
  done
}

cdx_log_timings_end() {
  cdx_flush_partial_timings

  _cdx_timing_log="/dev/null"
  _cdx_timing_prefix=""
}
