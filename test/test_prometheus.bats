#!/usr/bin/env bats
setup() {
  load test_helper/common_setup
  common_setup

  # shellcheck source=./src/prometheus.bash
  source "${LIB_SRC}/prometheus.bash"
  prom_set_outputs "${TEST_OUTPUTS}/prometheus"
}

contains() {
  local file="$1" pattern="$2"
  grep -F "$pattern" "$file" > /dev/null
}

@test "should create prometheus configurations on start callback" {
  prom_add "8290" "experiment" "84858" "node-1" "storage"

  config_file="${_prom_output}/8290-experiment-84858-node-1-storage.json"

  assert [ -f "${config_file}" ]

  assert contains "${config_file}" '"targets": ["host.docker.internal:8290"]'
  assert contains "${config_file}" '"job": "experiment"'
  assert contains "${config_file}" '"experiment_id": "84858"'
  assert contains "${config_file}" '"node": "node-1"'
  assert contains "${config_file}" '"node_type": "storage"'
}

@test "should remove prometheus configurations on stop callback" {
  prom_add "8290" "experiment" "84858" "node-1" "storage"

  config_file="${_prom_output}/8290-experiment-84858-node-1-storage.json"
  assert [ -f "${config_file}" ]

  prom_remove "8290" "experiment" "84858" "node-1" "storage"

  assert [ ! -f "${config_file}" ]
}