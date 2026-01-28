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

# Custom prefix for timing logs
_cdx_timing_prefix=""
# Log file where timings are aggregated
_cdx_timing_log="/dev/null"
# Base ports and timeouts
_cdx_base_api_port=8080
_cdx_base_disc_port=8190
_cdx_base_metrics_port=8290
_cdx_node_start_timeout=30
# Default options set for Logos Storage nodes
_cdx_defaultopts=()
# Log level for Logos Storage nodes.
_cdx_log_level="INFO"

echoerr "[storage] Node log level is ${_cdx_log_level}"

# PID array for known Logos Storage node processes
# FIXME: right now only processes destroyed with cdx_destroy_node are removed from
#   this array.
declare -A _cdx_pids

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

_cdx_disc_port() {
  local node_index="$1"
  echo $((_cdx_base_disc_port + node_index))
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

cdx_cmdline() {
  local node_index spr cdx_cmd="${_cdx_binary} --nat:none" opts=("$@")

  opts+=("${_cdx_defaultopts[@]}")

  node_index="${opts[0]}"
  shift_arr opts

  while [[ "${#opts[@]}" -gt 0 ]]; do
    opt="${opts[0]}"
    case "$opt" in
      --bootstrap-node)
        shift_arr opts
        spr="${opts[0]}"
        cdx_cmd="${cdx_cmd} --bootstrap-node=$spr"
        ;;
      --metrics)
        cdx_cmd="${cdx_cmd} --metrics --metrics-port=$(_cdx_metrics_port "$node_index") --metrics-address=0.0.0.0"
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

  # shellcheck disable=SC2140
  echo "${cdx_cmd}"\
 "--data-dir=${_cdx_data}/storage-${node_index} --api-port=$(_cdx_api_port "$node_index")"\
 "--disc-port=$(_cdx_disc_port "$node_index") '--log-level=${_cdx_log_level}'"
}

cdx_get_spr() {
  local node_index="$1" spr

  spr=$(curl --silent --fail "http://localhost:$(_cdx_api_port "$node_index")/api/storage/v1/debug/info" | grep -oe 'spr:[^"]\+')
  if [[ -z "$spr" ]]; then
    echoerr "Error: unable to get SPR for node $node_index"
    return 1
  fi

  echo "${spr}"
}

cdx_launch_node() {
  local node_index="$1"

  _cdx_init_global_outputs || return 1
  _cdx_init_node_outputs "${node_index}" || return 1

  local storage_cmd
  storage_cmd=$(cdx_cmdline "$@") || return 1

  cmd_array=()
  IFS=' ' read -r -a cmd_array <<<"$storage_cmd"

  pm_async "bash" "-c" "exec ${cmd_array[*]} &> ${_cdx_logs}/storage-${node_index}.log" -%- "storage" "${node_index}"
  _cdx_pids[$node_index]=$!

  cdx_ensure_ready "$node_index"
}

cdx_launch_network() {
  local node_count="$1" bootstrap_spr
  if [[ "$node_count" -lt 2 ]]; then
    echoerr "Error: a Logos Storage network needs at least 2 nodes"
    return 1
  fi

  cdx_launch_node 0 || return 1
  bootstrap_spr=$(cdx_get_spr 0) || return 1
  for i in $(seq 1 "$((node_count - 1))"); do
    cdx_launch_node "$i" "--bootstrap-node" "$bootstrap_spr" || return 1
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