#!/usr/bin/env bash
# shellcheck disable=SC2034

# Run with k-node.sh use_conf ./k-node-conf.sh <experiment_name>

# ----------------- Direct Transport ------------------

# Mid-sized swarm, mid-sized files, direct transport.
declare -A direct_50=(
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

# ------------------- Mix Transport -------------------

# Most basic case - can two nodes transfer data?
declare -A mix_2_5=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=2
  [seeder_count]=1
  [repetitions]=5
  [file_sizes_arr]="1 2 4"
  [stagger_delay]=0
  [relay_count]=5
  [relay_backend]="storage"
  [transport]="mix"
)

# Second most basic case - does it work for larger files?
declare -A mix_2_15=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=2
  [seeder_count]=1
  [repetitions]=5
  [file_sizes_arr]="8 16 32"
  [stagger_delay]=0
  [relay_count]=15
  [relay_backend]="storage"
  [transport]="mix"
)

# Does this work with a swarm?
declare -A mix_12_15=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=12
  [seeder_count]=3
  [repetitions]=5
  [file_sizes_arr]="1"
  [stagger_delay]=1
  [relay_count]=15
  [relay_backend]="storage"
  [transport]="mix"
)

# What if the swarm is larger than the mix?
declare -A mix_30_15_1=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=30 
  [seeder_count]=1
  [repetitions]=5
  [file_sizes_arr]="5"
  [stagger_delay]=1
  [relay_count]=15
  [relay_backend]="storage"
  [transport]="mix"
)

declare -A mix_30_15_5_5=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=30
  [relay_count]=15
  [file_sizes_arr]="5"
  [seeder_count]=5
  [repetitions]=5
  [stagger_delay]=1
  [relay_backend]="storage"
  [transport]="mix"
)

declare -A mix_30_15_5_15=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=30 
  [relay_count]=15
  [file_sizes_arr]="5"
  [seeder_count]=15
  [repetitions]=5
  [stagger_delay]=1
  [relay_backend]="storage"
  [transport]="mix"
)

declare -A mix_30_15_5_15=(
  [storage_log_level]="INFO;trace:blockexcnetwork,blockexcengine"
  [node_count]=50
  [relay_count]=50
  [file_sizes_arr]="5"
  [seeder_count]=15
  [repetitions]=5
  [stagger_delay]=1
  [relay_backend]="storage"
  [transport]="mix"
)
