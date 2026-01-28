#!/usr/bin/env bats
# shellcheck disable=SC2128,SC2076
setup() {
  load test_helper/common_setup
  common_setup

  # shellcheck source=./src/experiment.bash
  source "${LIB_SRC}/experiment.bash"
  exp_set_outputs "${TEST_OUTPUTS}"
  prom_set_outputs "${TEST_OUTPUTS}/prometheus"
}

@test "should create experiment folder and set it as the global harness output" {
  exp_start "experiment-type"

  experiment_output="${TEST_OUTPUTS}/experiment-type-[0-9]+-[0-9]+"
  found=false

  for output in "${TEST_OUTPUTS}"/*; do
    if [[ "$output" =~ ${experiment_output} ]]; then
      found=true
    fi
  done

  assert [ "$found" = true ]
}

@test "should launch Logos Storage nodes with metrics enabled when there is an experiment in scope" {
  exp_start "experiment-type"

  [[ "$(cdx_cmdline 0)" =~ "--metrics-port=8290 --metrics-address=0.0.0.0" ]]
}

@test "should add a prometheus target for each Logos Storage node when there is an experiment in scope" {
  exp_start "k-node"

  pm_start
  cdx_launch_node 0

  config_file="${_prom_output}/8290-k-node-${_experiment_id}-0-storage.json"
  assert [ -f "$config_file" ]

  cdx_destroy_node 0
  assert [ ! -f "$config_file" ]
}

teardown() {
  if pm_is_running; then
    pm_stop
  fi
}
