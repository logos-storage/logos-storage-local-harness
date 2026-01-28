#!/usr/bin/env bash
set -o pipefail

LIB_SRC=${LIB_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# shellcheck source=./src/utils.bash
source "${LIB_SRC}/utils.bash"
# shellcheck source=./src/storage.bash
source "${LIB_SRC}/storage.bash"
# shellcheck source=./src/prometheus.bash
source "${LIB_SRC}/prometheus.bash"

_experiment_type=""
_experiment_id=""

exp_set_outputs() {
  _exp_outputs="${1}"

  mkdir -p "${_exp_outputs}" || return 1
}

_ensure_outputs_set() {
  if [ -z "${_exp_outputs}" ]; then
    echoerr "experiments output not set"
    return 1
  fi
}

exp_start() {
  local experiment_id experiment_type="$1"

  _ensure_outputs_set || return 1

  experiment_id="$(date +%s)-${RANDOM}" || return 1

  _experiment_id="${experiment_id}"
  _experiment_type="${experiment_type}"
  _experiment_output="${_exp_outputs}/${experiment_type}-${experiment_id}"

  mkdir -p "${_experiment_output}" || return 1
  pm_set_outputs "${_experiment_output}/pm"
  cdx_set_outputs "${_experiment_output}/storage"

  cdx_add_defaultopts "--metrics"

  pm_register_callback "storage" _storage_target_changed

  echoerr "[exp] Experiment ID is ${experiment_id}"
}

_storage_target_changed() {
  local event="$1"
  if [ "$event" = "start" ]; then
    shift 3
    _add_target "$@"
  elif [ "$event" = "exit" ]; then
    shift 4
    _remove_target "$@"
  fi
}

_add_target() {
  local node_index="$1" metrics_port
  metrics_port=$(_cdx_metrics_port "$node_index") || return 1

  prom_add "${metrics_port}" "${_experiment_type}" "${_experiment_id}"\
    "${node_index}" "storage"
}

_remove_target() {
  local node_index="$1" metrics_port
  metrics_port=$(_cdx_metrics_port "$node_index") || return 1

  prom_remove "${metrics_port}" "${_experiment_type}" "${_experiment_id}"\
    "${node_index}" "storage"
}
