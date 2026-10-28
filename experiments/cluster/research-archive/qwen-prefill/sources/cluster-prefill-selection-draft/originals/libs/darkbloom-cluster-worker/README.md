# Darkbloom native cluster worker

This separate package builds the experimental resident rank worker. Its macOS
26.2 deployment minimum enables native JACCL while the provider-facing control
modules retain macOS 14. Provider startup does not enable this worker yet.

Build from the repository root with an explicitly source-matched metallib:

```sh
bash libs/darkbloom-cluster-worker/build-native-worker.sh \
  "$PWD/libs/darkbloom-cluster-worker" \
  /absolute/path/to/mlx.metallib \
  EXPECTED_METALLIB_SHA256
```

Use the [native dependency build procedure](../../experiments/cluster/inference/README.md)
to obtain a metallib matching the checked-out MLX sources. The script builds
with two jobs and explicit Swift/C++ deployment targets, then requires actual
JACCL symbols and a Mach-O deployment minimum of exactly macOS 26.2. A successful
build copies the verified metallib beside the worker and prints its path.

The worker consumes bounded protocol commands through owned pipes and runs
native work on its private main-thread executor. A separate control reader
handles cancellation; the enclosing owner must also fence blocked native work.
The optional bootstrap attachment requires all three flags together:
`--bootstrap-socket-path`, `--bootstrap-owner-pid`, and
`--bootstrap-deadline-uptime-nanoseconds`. It checks the actual parent identity
and connects before native group initialization. The owning launcher must
require this attachment for the authenticated peer path; omitting it retains
the experimental native bootstrap. The shared control module includes the paired
relay and a private configured owner for qualification. Cross-host execution and
the installed provider launcher remain under integration.
Neither a worker build nor a pipe fixture qualifies remote ownership, model
correctness, external TTFT, or production serving.

See the [shared modules](../darkbloom-cluster/README.md),
[execution plan](../../docs/design/distributed-cluster-execution-plan.md), and
[remote owner design](../../docs/design/distributed-peer-owner.md).
