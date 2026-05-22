#!/usr/bin/env bash
#
# k-nodes runs a Logos Storage network with k nodes in which a file is
# uploaded to node zero and then the remainder k - 1 nodes download it
# concurrently.
#
# Outputs download times to a log file.
#
# Usage: k-node.sh <node_count> <seeder_count> <repetitions> <output_log> [stagger_delay] [mix_enabled] [relay_backend] <file_sizes...>
#
# Arguments:
#   stagger_delay  - Optional delay in seconds between starting each leecher (default: 0 = simultaneous)
#   mix_enabled    - Optional true|false. When true, DHT lookups are routed
#                    through the Mix protocol via dht-proxy.
#   relay_backend  - Optional standalone|storage|mix_relay_dht (default: storage).
#                    Only meaningful when mix_enabled=true.
#                      standalone    -> mix_relay_dht binary with --no-dht-proxy
#                                       (pure Mix relay, no DHT)
#                      storage       -> use the storage binary as a Mix relay
#                      mix_relay_dht -> mix_relay_dht binary
#                                       (relay + DHT proxy)
set -e -o pipefail

# Default block size used by storage when chunking uploaded files (KB).
BLOCK_SIZE_KB=64

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=./src/clh
source "${SCRIPT_DIR}/../src/clh"

node_count="${1:-2}"
seeder_count="${2:-1}"
repetitions="${3:-1}"
output_log="${4:-"${OUTPUTS}/k-node-$(date +%s)-${RANDOM}.csv"}"
stagger_delay="${5:-0}"
mix_enabled="${6:-false}"
relay_backend="${7:-storage}"

case "${relay_backend}" in
  standalone|storage|mix_relay_dht) ;;
  *)
    echoerr "Error: invalid relay_backend='${relay_backend}'" \
      "(use 'standalone', 'storage', or 'mix_relay_dht')"
    exit 1
    ;;
esac

export CDX_MIX_RELAY_BACKEND="${relay_backend}"

if [ "$#" -gt 7 ]; then
  shift 7
  file_sizes=("$@")
else
  echoerr "No file sizes specified, using default (100)."
  file_sizes=("100")
fi

exp_start "k-node"

echoerr "* Nodes: ${node_count}"
echoerr "* Seeders: ${seeder_count}"
echoerr "* Repetitions: ${repetitions}"
echoerr "* File Sizes: ${file_sizes[*]}"
echoerr "* Stagger Delay: ${stagger_delay}s"
echoerr "* Timing log: ${output_log}"
if [ "$mix_enabled" = "true" ]; then
  echoerr "* Relay backend: ${relay_backend}"
fi

relay_count="${_cdx_mix_min_pool}"

if [ "$mix_enabled" = "true" ]; then
  cdx_require_mix_pool_binary || exit 1

  if [ "${relay_backend}" = "standalone" ]; then
    cdx_require_mix_relay_dht_binary || exit 1
  fi

  mix_pool_dir="${_experiment_output}/mix-pool"
  cdx_generate_mix_pool "${relay_count}" "${mix_pool_dir}" || exit 1

  export CDX_MIX_POOL_DIR="${mix_pool_dir}"
  export CDX_MIX_ENABLED=true

  echoerr "* Mix: enabled, ${relay_count} relays via ${relay_backend} backend," \
    "pool=${mix_pool_dir}/pool.json"
else
  echoerr "* Mix: disabled"
fi

# TODO: procmon management should be moved into
#  experiment lifecycle management.
# TODO: we should register this process with procmon
#  so its also killed if something fails.
trap "cdx_stop_relays; cdx_stop_bootstrap; pm_stop" EXIT INT TERM
pm_start

cdx_set_log_level "INFO;info:blockexcnetwork,blockexcengine,discoveryengine"
cdx_set_relay_log_level "INFO"

cdx_launch_bootstrap || exit 1
bootstrap_spr=$(cdx_get_bootstrap_spr) || exit 1

if [ "$mix_enabled" = "true" ]; then
  cdx_launch_relays "${relay_count}" "${bootstrap_spr}" || exit 1
fi

cdx_launch_network "${node_count}" "${bootstrap_spr}"

for file_size in "${file_sizes[@]}"; do
  for i in $(seq 1 "${repetitions}"); do
    file_name=$(cdx_generate_file "${file_size}")
    for j in $(seq 0 "$((seeder_count - 1))"); do
      cid=$(cdx_upload_file "${j}" "${file_name}")
    done

    cdx_log_timings_start "${output_log}" "${file_size},${i},${cid}"

    handles=()
    for j in $(seq "${seeder_count}" "$((node_count - 1))"); do
      if [ "$stagger_delay" -gt 0 ] && [ "$j" -gt "${seeder_count}" ]; then
        echoerr "Staggering: waiting ${stagger_delay}s before starting leecher $j..."
        sleep "$stagger_delay"
      fi

      echoerr "Starting leecher $j download..."
      cdx_download_file_async "$j" "$cid"
      # shellcheck disable=SC2128
      handles+=("$result")
    done

    await_all "${handles[@]}" "Inf"

    cdx_log_timings_end

    echoerr "=== Memory usage ==="
    for j in $(seq 0 "$((node_count - 1))"); do
      storage_pid=$(pgrep -f "storage.*--data-dir.*storage-$j" | head -1)
      if [ -z "$storage_pid" ]; then
        echoerr "Node $j: storage process not found"
        continue
      fi
      mem=$(ps -p "$storage_pid" -o rss= 2>/dev/null | awk '{print int($1/1024)}')
      [ -n "$mem" ] && echoerr "Node $j (PID $storage_pid): ${mem} MB"
    done

    echoerr ""
    echoerr "=== Blocks served per node (peer-to-peer analysis) ==="
    total_blocks_served=0
    seeder_blocks_served=0
    leecher_blocks_served=0

    for j in $(seq 0 "$((node_count - 1))"); do
      node_type="leecher"
      if [ "$j" -lt "$seeder_count" ]; then
        node_type="seeder"
      fi

      # Query Prometheus metrics endpoint for storage_block_exchange_blocks_sent
      blocks_served=$(curl -s "http://localhost:$(_cdx_metrics_port "$j")/metrics" 2>/dev/null | \
        grep '^storage_block_exchange_blocks_sent_total' | \
        awk '{printf "%.0f", $2}')

      if [ -z "$blocks_served" ]; then
        echoerr "Node $j ($node_type): Unable to query metrics"
      else
        echoerr "Node $j ($node_type): $blocks_served blocks sent"
        total_blocks_served=$((total_blocks_served + blocks_served))
        if [ "$node_type" = "seeder" ]; then
          seeder_blocks_served=$((seeder_blocks_served + blocks_served))
        else
          leecher_blocks_served=$((leecher_blocks_served + blocks_served))
        fi
      fi
    done

    expected_blocks=$((file_size * 1024 / BLOCK_SIZE_KB))
    total_downloads=$((node_count - seeder_count))
    seeder_expected=$((expected_blocks * total_downloads))

    echoerr "---"
    echoerr "Total blocks served by all nodes: $total_blocks_served"
    echoerr "  Seeder(s) served: $seeder_blocks_served blocks"
    echoerr "  Leechers served: $leecher_blocks_served blocks"
    echoerr ""
    echoerr "Expected seeder load (no peer-to-peer): $seeder_expected blocks"

    if [ "$seeder_blocks_served" -lt "$seeder_expected" ]; then
      seeder_savings=$((seeder_expected - seeder_blocks_served))
      seeder_percent=$((seeder_savings * 100 / seeder_expected))
      echoerr "Seeder bandwidth savings: $seeder_savings blocks ($seeder_percent%)"
      if [ "$total_blocks_served" -gt 0 ]; then
        p2p_ratio=$((leecher_blocks_served * 100 / total_blocks_served))
        echoerr "Peer-to-peer ratio: $p2p_ratio% of blocks served by leechers"
      fi
    else
      echoerr "No peer-to-peer detected (seeder served all or more blocks)"
    fi
    echoerr "=== End blocks served analysis ==="
  done
done
