#!/usr/bin/env bash
#
# k-nodes runs a Codex network with k nodes in which a file is uploaded to
# node zero and then the remainder k - 1 nodes download it concurrently.
#
# Outputs download times to a log file.
#
# Usage: k-node.sh <node_count> <repetitions> <output_log> <file_sizes...>
#
# Example: k-node.sh 5 10 ./k-node-5-10.csv 100 200 500
set -e -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=./src/clh
source "${SCRIPT_DIR}/../src/clh"

node_count="${1:-2}"
seeder_count="${2:-1}"
repetitions="${3:-1}"
output_log="${4:-"${OUTPUTS}/k-node-$(date +%s)-${RANDOM}.csv"}"

if [ "$#" -gt 4 ]; then
  shift 4
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
echoerr "* Timing log: ${output_log}"

# TODO: procmon management should be moved into
#  experiment lifecycle management.
# TODO: we should register this process with procmon
#  so its also killed if something fails.
trap pm_stop EXIT INT TERM
pm_start

cdx_set_log_level "INFO;trace:blockexcnetwork,blockexcengine,discoveryengine"
cdx_launch_network "${node_count}"

for file_size in "${file_sizes[@]}"; do
  for i in $(seq 1 "${repetitions}"); do
    file_name=$(cdx_generate_file "${file_size}")
    for j in $(seq 0 "$((seeder_count - 1))"); do
      cid=$(cdx_upload_file "${j}" "${file_name}")
    done

    cdx_log_timings_start "${output_log}" "${file_size},${i},${cid}"

    handles=()
    for j in $(seq "${seeder_count}" "$((node_count - 1))"); do
      cdx_download_file_async "$j" "$cid"
      # shellcheck disable=SC2128
      handles+=("$result")
    done

    await_all "${handles[@]}" "Inf"

    cdx_log_timings_end
  done
done
