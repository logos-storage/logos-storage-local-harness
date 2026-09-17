# logos-storage-local-harness

A local, 100% bash-based implementation of a Logos Storage harness that can be used to launch
a cluster and run experiments against it.

Some features:

**Containerless.** Compile your binary and you are ready to go. No need to build
Docker images or fiddle with container networking. This makes this particularly suitable for
quick experimentation: edit the code, compile, launch the cluster.

**Monitoring.** The harness includes a Grafana/Prometheus setup which runs on containers and
can be started with docker compose. The harness will automatically add Logos Storage
processes to Prometheus monitoring with proper experiment and node labels.

**Primitives.** The harness is built as a collection of primitives which allow:
   1. setting up and tearing down Logos Storage nodes;
   2. scripting nodes.

It has been designed with experimentation in mind: setting up scenarios in which nodes are
started/stopped and execute a concerted set of actions over which we then do measurements.
The harness supports concurrent actions and exposes simple future-like synchronization
primitives.

## Requirements

- Linux with Bash 4.3 or newer. The scripts use GNU utilities, including
  `grep -P` and `ps --ppid`; the default macOS tools are not sufficient.
- `curl`, `sha1sum`, `realpath`, `awk`, `sed`, `grep`, `ps`, `pgrep`, and the
  usual core utilities (`dd`, `seq`, etc.).
- A compiled Logos Storage executable, specified through `STORAGE_BINARY`.
- `unzip` if using the included binary download script.
- Optional: Docker with Compose for monitoring.
- For Mix experiments: compatible Storage and `mix_pool` binaries; the
  `standalone` and `mix_relay_dht` relay backends also need `mix_relay_dht`.

## Getting started

Run these commands from the repository root. Download a Storage release:

```bash
bash scripts/get-logos-storage.sh ./bin
export STORAGE_BINARY="$PWD/bin/storage"
```

The downloader selects the first release returned by GitHub. Set
`STORAGE_VERSION` to a release tag to select a specific version. To use your
own build instead:

```bash
export STORAGE_BINARY=/absolute/path/to/storage
```

Run a small experiment with two nodes, one seeder, one repetition, and a
1 MiB file over direct transport:

```bash
bash experiments/k-node.sh 2 1 1 ./download-times.csv 0 0 storage direct 1
```

The harness creates an experiment directory under `outputs/` with process
monitor state and Storage data, logs, generated files, downloads, and timing
fragments. The experiment appends download timings to the requested CSV file
and stops its managed processes on exit.

### Environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `STORAGE_BINARY` | Path to the Storage executable | Required |
| `OUTPUTS` | Experiment output directory | `outputs/` in this repository |
| `PROM_TARGETS_DIR` | Prometheus discovery files | `dashboard/targets/` in this repository |
| `MIX_POOL_BINARY` | Path to the `mix_pool` executable | Required when relays are enabled |
| `MIX_RELAY_DHT_BINARY` | Path to the `mix_relay_dht` executable | Required for the `standalone` and `mix_relay_dht` backends |

Set these before running an experiment or sourcing `src/clh`. If you change
`PROM_TARGETS_DIR`, also update the target-directory mount in the Compose file.
Node ports are allocated from 8000; run one harness network at a time to avoid
port collisions.

## Monitoring

Start Prometheus and Grafana before launching an experiment:

```bash
mkdir -p dashboard/targets
(cd dashboard && bash launch.sh -d)
```

- Grafana: <http://localhost:3000> (anonymous access is enabled).
- Prometheus: <http://localhost:9090>.

Storage nodes are added to and removed from Prometheus discovery as they start
and stop, with experiment and node labels. Dashboard provisioning is included
under `dashboard/grafana/`.

Stop monitoring with:

```bash
(cd dashboard && docker compose down)
```

## Writing experiments

Source `src/clh` from a Bash script to initialize the libraries and output paths.
Call `exp_start` before `pm_start` to configure the process monitor's output
directory, and install a cleanup trap:

```bash
#!/usr/bin/env bash
source ./src/clh

exp_start "example"
trap 'pm_stop' EXIT INT TERM
pm_start

cdx_launch_network 2 0
file=$(cdx_generate_file 1)
cid=$(cdx_upload_file 0 "$file")
cdx_download_file_async 1 "$cid" direct
download_pid="${result[0]}"
pm_await "$download_pid" Inf
cdx_check_download 0 1 "$cid"
```

Run this example from the repository root with `STORAGE_BINARY` set. Async
operations return their process handle in `result`; copy it before starting
another operation.

| Library | Responsibilities |
| --- | --- |
| [experiment.bash](src/experiment.bash) | Experiment directories and monitoring callbacks |
| [storage.bash](src/storage.bash) | Nodes, relays, uploads, downloads, and timings |
| [procmon.bash](src/procmon.bash) | Background jobs, waiting, and process cleanup |
| [networks.bash](src/networks.bash) | Named networks and port allocation |
| [prometheus.bash](src/prometheus.bash) | Prometheus discovery files |
| [utils.bash](src/utils.bash) | Configuration loading and general helpers |

## Experiments

The included experiment is **k-node**, which measures concurrent downloads from
a local Storage network. See [experiments/README.md](experiments/README.md) for
configuration presets and command-line usage.

## Tests

Initialize the test dependencies and run the Bats suite with `STORAGE_BINARY`
set:

```bash
git submodule update --init --recursive
./test/bats/bin/bats test/
```

CI also checks the shell scripts with ShellCheck.
