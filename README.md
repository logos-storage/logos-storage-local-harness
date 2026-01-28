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

