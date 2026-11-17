#!/usr/bin/env bats
# shellcheck disable=SC2128,SC2076
setup() {
  load test_helper/common_setup
  common_setup

  # shellcheck source=./src/storage.bash
  source "${LIB_SRC}/storage.bash"

  pm_set_outputs "${TEST_OUTPUTS}/pm"
  cdx_set_outputs "${TEST_OUTPUTS}/storage"
  expected_bootstrap=""
  if [[ "$("${_cdx_binary}" --help)" == *--no-bootstrap-node* ]]; then
    expected_bootstrap=" --no-bootstrap-node"
  fi
  expected_discovery=""
  if [[ "$("${_cdx_binary}" --help)" == *--disc-port* ]]; then
    expected_discovery=" --disc-port=$(net_port storage discovery 0)"
  fi
}

@test "should generate the correct Logos Storage command line for node 0" {
  # shellcheck disable=SC2140
  assert_equal "$(cdx_cmdline 0)" "${_cdx_binary} --nat=extip:127.0.0.1 --listen-ip=127.0.0.1"\
"${expected_bootstrap}"\
" --data-dir=${_cdx_output}/data/storage-0"\
" --api-port=$(net_port 'storage' 'api' 0) --listen-port=$(net_port 'storage' 'listen' 0) --log-level=INFO${expected_discovery}"
}

@test "should generate the correct Logos Storage command line for node 1" {
  local expected_node1_discovery=""
  if [[ -n "$expected_discovery" ]]; then
    expected_node1_discovery=" --disc-port=$(net_port storage discovery 1)"
  fi
  # shellcheck disable=SC2140
  assert_equal "$(cdx_cmdline 1 '--bootstrap-node' 'node-spr')" "${_cdx_binary} --nat=extip:127.0.0.1 --listen-ip=127.0.0.1"\
" --bootstrap-node=node-spr"\
" --data-dir=${_cdx_output}/data/storage-1"\
" --api-port=$(net_port 'storage' 'api' 1) --listen-port=$(net_port 'storage' 'listen' 1) --log-level=INFO${expected_node1_discovery}"
}

@test "should refuse to generate the command line for node > 0 if no SPR is provided" {
  assert cdx_cmdline 1 "--bootstrap-node" "spr"
  refute cdx_cmdline 1
}

@test "should generate metrics options when metrics enabled for node" {
  # shellcheck disable=SC2140
  assert_equal "$(cdx_cmdline 0 --metrics)" "${_cdx_binary} --nat=extip:127.0.0.1 --listen-ip=127.0.0.1"\
" --metrics --metrics-port=$(net_port 'storage' 'metrics' 0) --metrics-address=0.0.0.0"\
"${expected_bootstrap}"\
" --data-dir=${_cdx_output}/data/storage-0"\
" --api-port=$(net_port 'storage' 'api' 0) --listen-port=$(net_port 'storage' 'listen' 0) --log-level=INFO${expected_discovery}"
}

@test "should modify the Logos Storage log-level when specified" {
  cdx_set_log_level "DEBUG"

  # shellcheck disable=SC2140
  assert_equal "$(cdx_cmdline 0)" "${_cdx_binary} --nat=extip:127.0.0.1 --listen-ip=127.0.0.1"\
"${expected_bootstrap}"\
" --data-dir=${_cdx_output}/data/storage-0"\
" --api-port=$(net_port 'storage' 'api' 0) --listen-port=$(net_port 'storage' 'listen' 0) --log-level=DEBUG${expected_discovery}"
}

@test "should allow setting of global default options" {
  [[ ! "$(cdx_cmdline 0)" =~ "--metrics --metrics-port=$(net_port 'storage' 'metrics' 0) --metrics-address=0.0.0.0" ]]

  cdx_add_defaultopts "--metrics"

  [[ "$(cdx_cmdline 0)" =~ "--metrics --metrics-port=$(net_port 'storage' 'metrics' 0) --metrics-address=0.0.0.0" ]]

  cdx_clear_defaultopts

  [[ ! "$(cdx_cmdline 0)" =~ "--metrics --metrics-port=$(net_port 'storage' 'metrics' 0) --metrics-address=0.0.0.0" ]]
}

@test "should fail readiness check if node is not running" {
  refute cdx_ensure_ready 0 1
}

@test "should pass readiness check if node is running" {
  pm_start
  assert cdx_launch_node 0
  assert cdx_ensure_ready 0 3
  pm_stop
}

@test "should launch a Logos Storage node" {
  pm_start

  assert cdx_launch_node 0
  assert cdx_ensure_ready 0 3

  # We should see a log file and a data directory.
  assert [ -f "${_cdx_output}/logs/storage-0.log" ]
  assert [ -d "${_cdx_output}/data/storage-0" ]

  [[ "$(cdx_get_spr 0 'storage')" =~ ^"spr:" ]]

  pm_stop
}

@test "should check downloaded content" {
  mkdir -p "${_cdx_genfiles}"
  mkdir -p "${_cdx_uploads}/storage-0"
  mkdir -p "${_cdx_downloads}/storage-1"

  filename=$(cdx_generate_file 10)

  sha1 "$filename" > "${_cdx_uploads}/storage-0/fakecid.sha1"
  cp "$filename" "${_cdx_downloads}/storage-1/fakecid"

  # Checks that the file uploaded at 0 matches the file downloaded at 1.
  assert cdx_check_download 0 1 "fakecid"
}

@test "should upload and synchronously download file from Logos Storage node" {
  pm_start

  assert cdx_launch_node 0
  assert cdx_ensure_ready 0 3

  filename=$(cdx_generate_file 10)
  cid=$(cdx_upload_file 0 "$filename")

  assert cdx_download_file 0 "$cid"

  assert cdx_check_download 0 0 "$cid"

  pm_stop
}

@test "should upload and asynchronously download file from Logos Storage node" {
  pm_start

  assert cdx_launch_node 0
  assert cdx_ensure_ready 0 3

  filename=$(cdx_generate_file 10)
  cid=$(cdx_upload_file 0 "$filename")

  cdx_download_file_async 0 "$cid"
  handle=$result

  pm_await "$handle" 3

  assert cdx_check_download 0 0 "$cid"

  pm_stop
}

@test "should refuse to launch a Logos Storage network with less than 2 nodes" {
  refute cdx_launch_network 1
}

@test "should use node 0 as the bootstrap node" {
  unset CDX_MIX_ENABLED
  launched_nodes=()

  # shellcheck disable=SC2329
  cdx_launch_node() {
    launched_nodes+=("$*")
  }

  # shellcheck disable=SC2329
  cdx_get_spr() {
    [[ "$1" -eq 0 ]] || return 1
    echo "node-zero-spr"
  }

  assert cdx_launch_network 3
  assert_equal "${#launched_nodes[@]}" 3
  assert_equal "${launched_nodes[0]}" "0"
  assert_equal "${launched_nodes[1]}" "1 --bootstrap-node node-zero-spr"
  assert_equal "${launched_nodes[2]}" "2 --bootstrap-node node-zero-spr"
}

@test "should launch Mix relays after node 0" {
  export CDX_MIX_ENABLED=true
  export CDX_MIX_RELAY_BACKEND=standalone
  launched_nodes=()
  relay_launch=""

  # shellcheck disable=SC2329
  cdx_launch_node() {
    launched_nodes+=("$*")
  }

  # shellcheck disable=SC2329
  cdx_get_spr() {
    if [[ -z "$2" ]]; then
      [[ "$1" -eq 0 ]] || return 1
      echo "bootstrap-spr"
    elif [[ "$2" == "relay" ]]; then
      [[ "$1" -eq 0 ]] || return 1
      echo "relay-spr"
    else
      return 1
    fi
  }

  # shellcheck disable=SC2329
  cdx_launch_relays() {
    relay_launch="$*"
  }

  cdx_private_queries() {
    return 0
  }

  assert cdx_launch_network 2 4
  assert_equal "${relay_launch}" "${_cdx_mix_min_pool} bootstrap-spr"
  assert_equal "${launched_nodes[0]}" "0"
  assert_equal "${launched_nodes[1]}" \
    "1 --bootstrap-node bootstrap-spr --dht-mix-proxy relay-spr"
}

@test "should launch a Logos Storage network and allow uploading and downloading" {
  pm_start

  assert cdx_launch_network 5

  filename=$(cdx_generate_file 10)
  cid=$(cdx_upload_file 0 "$filename")

  handles=()
  for i in {1..4}; do
    cdx_download_file_async "$i" "$cid"
    handles+=("$result")
  done

  assert pm_await_all "${handles[@]}"

  for i in {1..4}; do
    assert cdx_check_download 0 "$i" "$cid"
  done

  pm_stop
}

@test "should log download timing information when requested" {
  pm_start

  cdx_log_timings_start "${_cdx_output}/experiment-0.csv" "experiment-0,100MB"

  assert cdx_launch_network 5

  filename=$(cdx_generate_file 10)
  cid=$(cdx_upload_file 0 "$filename")

  handles=()
  for i in {1..4}; do
    cdx_download_file_async "$i" "$cid"
    handles+=("$result")
  done

  assert pm_await_all "${handles[@]}"

  for i in {1..4}; do
    assert cdx_check_download 0 "$i" "$cid"
  done

  cdx_log_timings_end
  pm_stop

  assert [ -f "${_cdx_output}/experiment-0.csv" ]
  assert [ "$(<"${_cdx_output}/experiment-0.csv" wc -l)" -eq 4 ]

  decimal_regex='^[0-9]+(\.[0-9]+)?$'

  while IFS=',' read -r experiment file_size operation transport node_index recorded_cid wallclock user system; do
    assert [ "$experiment" = "experiment-0" ]
    assert [ "$file_size" = "100MB" ]
    assert [ "$recorded_cid" = "$cid" ]
    assert [ "$operation" = "download" ]
    assert [ "$transport" = "direct" ]

    # We can't use asserts for regex matches so use "raw" bats
    # assertions.
    [[ "$node_index" =~ [1-4] ]]
    [[ "$wallclock" =~ $decimal_regex ]]
    [[ "$user" =~ $decimal_regex ]]
    [[ "$system" =~ $decimal_regex ]]
  done < "${_cdx_output}/experiment-0.csv"
}

teardown() {
  # Bats skips the rest of a test after a failed assertion.
  if pm_is_running; then
    pm_stop
  fi
  if [[ "${BATS_TEST_COMPLETED:-}" != 1 && -d "${_cdx_logs}" ]]; then
    local destination="${BATS_TEST_DIRNAME}/../test_failures/storage-${BATS_TEST_NUMBER}"
    mkdir -p "$destination"
    cp -a "${_cdx_logs}/." "$destination/"
    echo "Storage failure logs retained in $destination" >&2
  fi
  clean_outputs
}

@test "should omit legacy discovery option for a current binary" {
  _cdx_binary="${BATS_TEST_TMPDIR}/storage-current"
  printf '#!/bin/sh\nprintf "%%s\n" --listen-port\n' > "$_cdx_binary"
  chmod +x "$_cdx_binary"
  run cdx_cmdline 0
  assert_success
  refute_output --partial -- '--disc-port'
}

@test "should allocate distinct discovery ports for release nodes and relays" {
  _cdx_binary="${BATS_TEST_TMPDIR}/storage-release"
  printf '#!/bin/sh\nprintf "%%s\n" --disc-port\n' > "$_cdx_binary"
  chmod +x "$_cdx_binary"
  assert_not_equal "$(_cdx_discovery_option storage 0)" "$(_cdx_discovery_option storage 1)"
  assert_not_equal "$(_cdx_discovery_option storage 0)" "$(_cdx_discovery_option relay 0)"
  run cdx_cmdline 1 --bootstrap-node node-spr
  assert_success
  assert_output --partial -- "--disc-port=$(net_port storage discovery 1)"
}

@test "should propagate failure to inspect the selected binary" {
  _cdx_binary=/bin/false
  run cdx_cmdline 0
  assert_failure
}
