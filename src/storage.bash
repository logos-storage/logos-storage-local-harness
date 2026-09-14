#!/usr/bin/env bash
set -eo pipefail

LIB_SRC=${LIB_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# shellcheck source=./src/utils.bash
source "${LIB_SRC}/utils.bash"
# shellcheck source=./src/procmon.bash
source "${LIB_SRC}/procmon.bash"
# shellcheck source=./src/networks.bash
source "${LIB_SRC}/networks.bash"

require_binary "_cdx_binary" "storage" "STORAGE_BINARY"

# Port ranges
net_declare "storage" 200
net_declare "relay" 100
net_decl_ports "storage" "api" "listen" "metrics"
net_decl_ports "relay" "api" "listen" "metrics"

# Minimum size for a mix pool
_cdx_mix_min_pool=4
# Custom prefix for timing logs
_cdx_timing_prefix=""
# Log file where timings are aggregated
_cdx_timing_log="/dev/null"

_cdx_node_start_timeout=30
_cdx_defaultopts=()
_cdx_log_level="INFO"
_cdx_relay_log_level="INFO"

echoerr "[storage] Node log level is ${_cdx_log_level}"
echoerr "[storage] Relay log level is ${_cdx_relay_log_level}"

cdx_generate_mix_pool() {
  local pool_size="$1" pool_dir="$2" binary
  require_binary "binary" "mix_pool" "MIX_POOL_BINARY" || return 1
  rm -rf "${pool_dir}"
  mkdir -p "${pool_dir}"
  "${binary}" init \
    --pool="${pool_dir}/pool.json" \
    --count="${pool_size}" \
    --base-port="$(net_base_port 'relay' 'listen')" \
    --outdir="${pool_dir}/relays" >&2 || return 1
}

cdx_launch_relay() {
  local relay_index="$1" bootstrap_spr="${2:-}" binary quoted_log_file
  local backend="${CDX_MIX_RELAY_BACKEND:-standalone}"
  local -a cmd_args

  if [ -z "${CDX_MIX_POOL_DIR:-}" ]; then
    echoerr "Error: cdx_launch_relay requires CDX_MIX_POOL_DIR"
    return 1
  fi

  _cdx_init_global_outputs || return 1

  data_dir="${CDX_MIX_POOL_DIR}/relays/relay_${relay_index}"
  log_file="${_cdx_logs}/relay-${backend}-${relay_index}.log"

  cmd_args=(
    "--data-dir=${data_dir}"
    "--listen-ip=127.0.0.1"
    "--listen-port=$(net_port 'relay' 'listen' "${relay_index}")"
    "--log-level=${_cdx_relay_log_level}"
  )

  case "${backend}" in
    standalone)
      require_binary "binary" "mix_relay_dht" "MIX_RELAY_DHT_BINARY" || return 1
      cmd_args+=("--no-dht-proxy")
      ;;
    mix_relay_dht)
      require_binary "binary" "mix_relay_dht" "MIX_RELAY_DHT_BINARY" || return 1
      if [[ -n "${bootstrap_spr}" ]]; then
        cmd_args+=("--bootstrap-node=${bootstrap_spr}")
      fi
      ;;
    storage)
      binary="${_cdx_binary}"
      cmd_args+=(
        "--nat=extip:127.0.0.1"
        "--api-port=$(net_port 'relay' 'api' "${relay_index}")"
        "--metrics-port=$(net_port 'relay' 'metrics' "${relay_index}")"
        "--bootstrap-node=${bootstrap_spr}"
        "--mix-enabled"
        "--mix-pool=${CDX_MIX_POOL_DIR}/pool.json"
      )
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

  # Relay has no HTTP endpoint to poll; brief sleep to let it bind the port.
  sleep 0.5
}

cdx_launch_relays() {
  local count="$1" bootstrap_spr="${2:-}" i
  echoerr "Launching ${count} Mix relays (backend: ${CDX_MIX_RELAY_BACKEND:-standalone})..."
  for i in $(seq 0 "$((count - 1))"); do
    cdx_launch_relay "$i" "${bootstrap_spr}" || return 1
  done
}

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
  local node_index spr="" opt cmd
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
          "--metrics-port=$(net_port 'storage' 'metrics' "${node_index}")"
          "--metrics-address=0.0.0.0"
        )
        ;;
      *)
        echoerr "Error: unknown option $opt"
        return 1
        ;;
    esac
    shift_arr opts
  done

  # FIXME I'm conventioning that node 0 is bootstrap, but this needs to be
  #   enforced properly.
  if [[ "$node_index" -eq 0 ]]; then
    cmd_args+=("--no-bootstrap-node")
  elif [[ -z "$spr" ]]; then
    echoerr "Error: SPR is required for node ${node_index}"
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
    "--api-port=$(net_port 'storage' 'api' "${node_index}")"
    "--listen-port=$(net_port 'storage' 'listen' "${node_index}")"
    "--log-level=${_cdx_log_level}"
  )

  printf -v cmd '%q ' "${cmd_args[@]}"
  printf '%s\n' "${cmd% }"
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

  cdx_ensure_ready "$node_index"
}

cdx_info() {
  local node_index="$1" network="${2:-storage}"
  curl --silent --fail "http://localhost:$(net_port "${network}" 'api' "${node_index}")/api/storage/v1/debug/info" || return 1
}

cdx_get_spr() {
  cdx_info "$@" | grep --color=never -oP '(?<="spr": ")[^"]+'
}

cdx_private_queries() {
  local enabled
  enabled=$(cdx_info "$@" | grep --color=never -oP '(?<="privateQueries": )[^,]+')
  [[ "$enabled" == "true" ]]
}

cdx_launch_network() {
  local node_count="$1" bootstrap_spr mix_node_spr relay_count i
  local -a extra_args=()

  if [[ "$node_count" -lt 2 ]]; then
    echoerr "Error: a Logos Storage network needs at least 2 nodes"
    return 1
  fi

  cdx_launch_node 0 || return 1
  bootstrap_spr=$(cdx_get_spr 0) || return 1

  if [[ "${CDX_MIX_ENABLED:-}" == "true" ]]; then
    relay_count="${_cdx_mix_min_pool}"
    cdx_launch_relays "${relay_count}" "${bootstrap_spr}" || return 1

    if [[ "${CDX_MIX_RELAY_BACKEND:-}" == "mix_relay_dht" ]]; then
      local mix_node_spr_file
      for i in $(seq 0 "$((relay_count - 1))"); do
        # Since the standalone Mix relays don't have an HTTP endpoint,
        # we have to wait for the mix_node.spr file to be written by
        # the relay as readyness check.
        mix_node_spr_file="${CDX_MIX_POOL_DIR}/relays/relay_${i}/mix_node.spr"
        await 6 [ -s "${mix_node_spr_file}" ]
        mix_node_spr=$(cat "${mix_node_spr_file}")
      done
    else
      # FIXME we should use all nodes as proxies, not just the bootstrap node.
      mix_node_spr=$(cdx_get_spr 0 'relay' || return 1)
    fi
    extra_args+=("--dht-mix-proxy" "$mix_node_spr")
  fi

  for i in $(seq 1 "$((node_count - 1))"); do
    cdx_launch_node "$i" "--bootstrap-node" "$bootstrap_spr" "${extra_args[@]}" || return 1
    if [[ "${CDX_MIX_ENABLED:-}" == "true" ]]; then
      cdx_private_queries "$i" || fail "Node ${i} does not have private queries enabled"
      echoerr "Node ${i} is using Mix relay ${mix_node_spr}"
    fi
  done
  return 0
}

cdx_ensure_ready() {
  local node_index="$1" timeout=${2:-$_cdx_node_start_timeout}
  echoerr "Waiting ${timeout} seconds for node ${node_index} to be ready."
  await "${timeout}" cdx_get_spr "$node_index" || return 1
  echoerr "Node ${node_index} is ready."
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
    -XPOST "http://localhost:$(net_port 'storage' 'api' "${node_index}")/api/storage/v1/data"\
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
    -XGET "http://localhost:$(net_port 'storage' 'api' "${node_index}")/api/storage/v1/data/$cid/network/stream"\
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
