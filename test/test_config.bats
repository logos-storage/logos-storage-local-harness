#!/usr/bin/env bats
setup() {
  load test_helper/common_setup
  common_setup

  # shellcheck source=./src/config.bash
  source "${LIB_SRC}/config.bash"

  config_fixture="${BATS_TEST_TMPDIR}/config with spaces.bash"
  cat > "$config_fixture" <<'EOF'
config_was_sourced=true
declare -A config=(
  [node_count]=2
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [file_sizes_arr]="1 2 4"
)
declare -A swarm=(
  [node_count]=12
  [storage_log_level]="DEBUG"
  [file_sizes_arr]="8 16 32"
)
EOF

  config_was_sourced=false
  cfg_node_count=99
  cfg_storage_log_level=original
  cfg_file_sizes=(100 500)
  cfg_name=original
}

@test "should apply the default config when use_conf is specified" {
  node_count=untouched
  storage_log_level=untouched
  file_sizes=(untouched)
  cfg_apply use_conf "$config_fixture"

  assert_equal "$node_count" untouched
  assert_equal "$storage_log_level" untouched
  assert_equal "${file_sizes[*]}" untouched

  assert_equal "$config_was_sourced" true
  assert_equal "$cfg_node_count" 2
  assert_equal "$cfg_storage_log_level" "INFO;trace:blockexcnetwork,blockexcengine"
  assert_equal "${#cfg_file_sizes[@]}" 3
  assert_equal "${cfg_file_sizes[0]}" 1
  assert_equal "${cfg_file_sizes[1]}" 2
  assert_equal "${cfg_file_sizes[2]}" 4
  assert_equal "$cfg_name" config
}

@test "should apply the requested named config when use_conf is specified" {
  cfg_apply use_conf "$config_fixture" swarm

  assert_equal "$config_was_sourced" true
  assert_equal "$cfg_node_count" 12
  assert_equal "$cfg_storage_log_level" DEBUG
  assert_equal "${#cfg_file_sizes[@]}" 3
  assert_equal "${cfg_file_sizes[0]}" 8
  assert_equal "${cfg_file_sizes[1]}" 16
  assert_equal "${cfg_file_sizes[2]}" 32
  assert_equal "$cfg_name" swarm
}

@test "should not source or apply config when the first argument is not use_conf" {
  for argument in 2 other USE_CONF ''; do
    # Call directly: Bats run would hide variable changes in a subshell.
    result=0
    cfg_apply "$argument" "$config_fixture" swarm || result=$?

    assert_equal "$result" 1
    assert_equal "$config_was_sourced" false
    assert_equal "$cfg_node_count" 99
    assert_equal "$cfg_storage_log_level" original
    assert_equal "${cfg_file_sizes[*]}" "100 500"
    assert_equal "$cfg_name" original
  done
}

@test "should return without applying config when no arguments are supplied" {
  result=0
  cfg_apply || result=$?

  assert_equal "$result" 1
  assert_equal "$config_was_sourced" false
  assert_equal "$cfg_node_count" 99
  assert_equal "$cfg_storage_log_level" original
  assert_equal "${cfg_file_sizes[*]}" "100 500"
  assert_equal "$cfg_name" original
}

@test "should not validate the config path when use_conf is not specified" {
  run cfg_apply 2 "${BATS_TEST_TMPDIR}/missing.bash" swarm

  assert_failure 1
  assert_output ''
}

@test "should fail when use_conf specifies a missing configuration file" {
  run cfg_apply use_conf "${BATS_TEST_TMPDIR}/missing.bash"

  assert_failure 1
  assert_output --partial 'configuration file not found'
}

@test "should format config values in the requested order" {
  cfg_apply use_conf "$config_fixture" swarm

  run cfg_par_string file_sizes_arr name node_count node_count

  assert_success
  assert_output '8 16 32,swarm,12,12'
}

@test "should quote CSV values containing commas quotes or newlines" {
  cfg_apply use_conf "$config_fixture"
  # shellcheck disable=SC2034 # Read indirectly by cfg_par_string.
  cfg_label=$'a "quoted" label\non two lines'

  run cfg_par_string node_count storage_log_level label

  assert_success
  assert_output $'2,"INFO;trace:blockexcnetwork,blockexcengine","a ""quoted"" label\non two lines"'
}

@test "should preserve literal shell characters in config arrays" {
  cat >> "$config_fixture" <<'EOF'
config[file_sizes_arr]='* $(whoami) "quoted"'
EOF
  cfg_apply use_conf "$config_fixture"

  assert_equal "${#cfg_file_sizes[@]}" 3
  assert_equal "${cfg_file_sizes[0]}" '*'
  # shellcheck disable=SC2016 # These shell characters must remain literal.
  assert_equal "${cfg_file_sizes[1]}" '$(whoami)'
  assert_equal "${cfg_file_sizes[2]}" '"quoted"'
  run cfg_par_string file_sizes_arr
  assert_success
  # shellcheck disable=SC2016
  assert_output '"* $(whoami) ""quoted"""'
}

@test "should preserve empty config values as CSV columns" {
  # shellcheck disable=SC2034 # Read indirectly by cfg_par_string.
  cfg_empty=''
  cfg_file_sizes=()

  run cfg_par_string empty node_count file_sizes_arr

  assert_success
  assert_output ',99,'
}

@test "should output an empty string when no config keys are requested" {
  run cfg_par_string

  assert_success
  assert_output ''
}

@test "should reject missing config keys without emitting a partial CSV string" {
  run --separate-stderr cfg_par_string node_count missing_key

  assert_failure 1
  assert_output ''
  assert_stderr 'Error: configuration key is not set: missing_key'
}

@test "should reject invalid config keys" {
  run cfg_par_string 'file_sizes[0]'

  assert_failure 1
  assert_output 'Error: invalid configuration key: file_sizes[0]'
}
