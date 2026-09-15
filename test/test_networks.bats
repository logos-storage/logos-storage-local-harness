setup() {
  load test_helper/common_setup
  common_setup

  # shellcheck source=./src/networks.bash
  source "${LIB_SRC}/networks.bash"
}


@test "should allow declaring a named network" {
  net_declare "storage" 100

  assert [ "$(net_size 'storage')" = 100 ]
}

@test "should allow declaring port ranges by name" {
  net_declare "storage" 100
  net_decl_port "storage" "api"
  net_decl_port "storage" "listen"
  net_decl_port "storage" "metrics"

  api_base=$(net_base_port "storage" "api")
  listen_base=$(net_base_port "storage" "listen")
  metrics_base=$(net_base_port "storage" "metrics")

  assert [ $((listen_base - api_base)) -ge 100 ]
  assert [ $((metrics_base - listen_base)) -ge 100 ]
}

@test "should map different ports to different nodes" {
  net_declare "storage" 100
  net_decl_port "storage" "api"
  net_decl_port "storage" "listen"
  net_decl_port "storage" "metrics"

  assert [ "$(net_port "storage" "api" 0)" != "$(net_port "storage" "api" 1)" ]
  assert [ "$(net_port "storage" "listen" 0)" != "$(net_port "storage" "listen" 1)" ]
  assert [ "$(net_port "storage" "metrics" 0)" != "$(net_port "storage" "metrics" 1)" ]
}

@test "should keep port ranges separate across networks of different sizes" {
  net_declare "storage" 100
  net_declare "relay" 20
  net_decl_port "storage" "api"
  net_decl_port "relay" "api"
  net_decl_port "storage" "listen"

  assert [ "$(net_port storage api 99)" -lt "$(net_port relay api 0)" ]
  assert [ "$(net_port relay api 19)" -lt "$(net_port storage listen 0)" ]
}

@test "should preserve port mappings when declarations are repeated" {
  net_declare "storage" 100
  net_decl_port "storage" "api"
  original_port=$(net_port storage api 99)

  net_declare "storage" 100
  net_decl_port "storage" "api"
  assert [ "$(net_port storage api 99)" = "$original_port" ]

  run net_declare "storage" 200
  assert_failure
  assert [ "$(net_size storage)" = 100 ]
}

@test "should reject undeclared ranges and nodes outside the network" {
  run net_decl_port "storage" "api"
  assert_failure

  net_declare "storage" 100
  run net_port "storage" "api" 0
  assert_failure

  net_decl_port "storage" "api"
  for node in -1 100 invalid; do
    run net_port "storage" "api" "$node"
    assert_failure
  done
}

@test "should clear declarations and reset port allocation" {
  net_declare "storage" 100
  net_decl_port "storage" "api"
  original_base=$(net_base_port "storage" "api")

  net_clear
  run net_size "storage"
  assert_failure
  run net_base_port "storage" "api"
  assert_failure

  net_declare "relay" 20
  net_decl_port "relay" "listen"
  assert [ "$(net_base_port "relay" "listen")" = "$original_base" ]
}

teardown() {
  net_clear
}
