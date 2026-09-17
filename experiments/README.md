# Experiments

## k-node

`k-node.sh` starts a local Storage network, generates a file, uploads it to the
first `seeder_count` nodes, and has the remaining nodes download it concurrently.
It repeats this for each file size and repetition, recording download timings
and printing memory usage and block-serving statistics. Downloads can use
direct or Mix transport, with an optional delay between starting downloaders.

Follow the [setup instructions](../README.md#getting-started) first. All commands
below run from the repository root with `STORAGE_BINARY` set.

### Run a configuration

```bash
bash experiments/k-node.sh use_conf ./experiments/k-node-conf.sh medium_direct
```

The named associative arrays in [k-node-conf.sh](k-node-conf.sh) are presets:

| Preset | Nodes / seeders | Sizes (MiB) | Repetitions | Relays | Transport |
| --- | --- | --- | --- | --- | --- |
| `medium_direct` | 50 / 5 | 100, 500 | 5 | 0 | direct |
| `two_node_small_mix` | 2 / 1 | 1, 2, 4 | 1 | 5 | mix |
| `two_node_larger_mix` | 2 / 1 | 8, 16, 32 | 1 | 15 | mix |

For a Mix preset, set the pool generator path as well:

```bash
export MIX_POOL_BINARY=/absolute/path/to/mix_pool
bash experiments/k-node.sh use_conf ./experiments/k-node-conf.sh two_node_small_mix
```

Edit or copy a preset to change its settings. Applied parameters have a `cfg_`
prefix: `node_count` becomes `cfg_node_count`, and `file_sizes_arr="1 2 4"`
becomes the global array `cfg_file_sizes=(1 2 4)`. Keys ending in `_arr` lose
that suffix and their values are split on spaces. `cfg_name` holds the preset
name. Sizes are integer MiB values without units.
Use at least two nodes and `1 <= seeder_count < node_count`.
`stagger_delay` is an integer number of seconds; log levels can be set with
`storage_log_level` and `relay_log_level` (both default to `INFO`).

`relay_count=0` disables Mix routing; enabling it currently requires at least
5 relays. The presets use the `storage` relay backend. The alternative
`standalone` and `mix_relay_dht` backends require `MIX_RELAY_DHT_BINARY`.

### Run matching configurations

```bash
bash experiments/runwith.bash experiments/k-node.sh experiments/k-node-conf.sh 'mix_*'
```

The runner selects associative arrays whose names match the quoted shell glob
(`'*'` selects all configurations), then runs the experiment sequentially in
alphabetical order using `use_conf <configuration_script> <configuration_name>`.
It continues after failed runs and exits nonzero if any run fails or no names
match. An interrupt stops the batch.

### Run with positional arguments

```text
bash experiments/k-node.sh NODE_COUNT SEEDER_COUNT REPETITIONS OUTPUT_LOG STAGGER_DELAY RELAY_COUNT RELAY_BACKEND TRANSPORT FILE_SIZES...
```

For two nodes, one seeder, three repetitions, and 1 and 10 MiB files:

```bash
bash experiments/k-node.sh 2 1 3 ./download-times.csv 0 0 storage direct 1 10
```

### Results

Logs and data are under `outputs/k-node-<timestamp>-<random>/` (or `$OUTPUTS`).
Timing rows are appended without a header, with fields:

```text
config_name,node_count,seeder_count,stagger_delay,relay_count,config_transport,file_size_mib,repetition,cid,download,transport,node_index,cid,real_seconds,user_seconds,sys_seconds
```

The configuration prefix is produced by
`cfg_par_string name node_count seeder_count stagger_delay relay_count transport`,
which takes original keys in column order. Each row then records the current
file size and repetition, followed by the CID and download timing fields.
Values containing commas, quotes, or newlines are CSV-quoted. Unknown keys
return an error. Positional runs use
`positional` as the configuration name and record the same parameter columns.

In configuration mode, an optional fourth argument sets the timing-log path;
otherwise it defaults to `$OUTPUTS/k-node-<timestamp>-<random>.csv`. Positional
mode uses `OUTPUT_LOG`. The script stops its managed processes when it exits.
