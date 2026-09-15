#!/usr/bin/env bash
# shellcheck disable=SC2034

# Run with k-node.sh use_conf ./k-node-conf.sh <experiment_name>

# Non-mix experiments.
declare -A medium_direct=(
  [storage_log_level]="INFO"
  [node_count]=50
  [seeder_count]=5
  [repetitions]=5
  [file_sizes_arr]="100 500"
  [stagger_delay]=1
  [transport]="direct"
  [relay_count]=0 # mix disabled
  [relay_backend]="storage" # ignored
)

# Mix experiments.
declare -A two_node_small_mix=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=2
  [seeder_count]=1
  [repetitions]=1
  [file_sizes_arr]="1 2 4"
  [stagger_delay]=0
  [relay_count]=5
  [relay_backend]="storage"
  [transport]="mix"
)

declare -A two_node_larger_mix=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=2
  [seeder_count]=1
  [repetitions]=1
  [file_sizes_arr]="8 16 32"
  [stagger_delay]=0
  [relay_count]=15
  [relay_backend]="storage"
  [transport]="mix"
)
