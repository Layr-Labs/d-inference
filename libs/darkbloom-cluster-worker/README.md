# Darkbloom native cluster worker

This separate package builds the experimental resident rank worker and a
two-rank transport check. Its macOS 26.2 deployment minimum is what makes the
pinned MLX compile the real JACCL backend (RDMA over Thunderbolt); below 26.2
`mlx-swift` compiles a stub. The provider and the shared
[`darkbloom-cluster`](../darkbloom-cluster/README.md) modules keep macOS 14, and
no submodule pin changes.

| Product | What it is |
|---|---|
| `darkbloom-cluster-worker` | One rank of a two-Mac resident session. Launched by `darkbloom cluster worker-owner`, never by hand in serving. |
| `darkbloom-cluster-collective-check` | Both ranks run it with the same arguments. It initializes the strict JACCL backend and verifies reductions and point-to-point transfers byte for byte. No model, no weights. |
| `darkbloom-cluster-stage-check` | One Mac, one rank, the real artifact, no collective. Runs the verified loader for that rank's layer range, releases it, and reports memory before, loaded and after. |

`Sources/DarkbloomClusterWorker`: `WorkerMain.swift` is the entry point.
`Startup/` parses startup and bootstrap arguments; `Capabilities/` serves
`--describe-runtime` metadata; `Execution/` holds `WorkerRuntime`,
`WorkerCoordinator` and `NativeWorkerRuntime`; `Transport/` is bounded pipe IO.

## Build

Build the matching Metal kernels from the checked-out MLX sources, then build a
product with that file and its hash:

```sh
bash scripts/fetch-metallib.sh /absolute/path/to/cluster-metal
shasum -a 256 /absolute/path/to/cluster-metal/mlx.metallib

bash libs/darkbloom-cluster-worker/build-native-worker.sh \
  "$PWD/libs/darkbloom-cluster-worker" \
  darkbloom-cluster-worker \
  /absolute/path/to/cluster-metal/mlx.metallib \
  EXPECTED_METALLIB_SHA256
```

The script builds with explicit Swift and C++ 26.2 targets, then refuses the
result unless the binary contains the JACCL group implementation and its Mach-O
minimum is exactly macOS 26.2. It copies the verified metallib beside the binary
and prints the binary path. `DARKBLOOM_CLUSTER_WORKER_BUILD_JOBS` sets the job
count (default 2). See the [provider build procedure](../../docs/developer/build.md)
for toolchain and submodule setup.

## Checks

```sh
# Metadata command and input helpers; no MLX, no model.
bash libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh

# Worker orchestration against a fake runtime (needs the 26.2 targets).
swift build --package-path libs/darkbloom-cluster-worker --build-tests \
  --triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2
swift test --package-path libs/darkbloom-cluster-worker --skip-build \
  --triple arm64-apple-macosx26.2
```

## Per-Mac stage check

Run on each Mac, for each rank it may serve, before any two-Mac attempt. The
arithmetic environment is the worker's and must be set exactly:

```sh
env DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1 \
  darkbloom-cluster-stage-check --model-dir /ABS/MODEL --rank 1 --stage-cut 4
```

It passes the same admission and host resource gates as the worker, hashes the
artifact, materializes only that rank's stage, then releases it. The JSON
receipt carries the verified aggregate, the storage commitment (equal on both
ranks and both Macs for one cut), loaded bytes, load time, and active and cached
bytes after release. Exit status is 0 only if the model object was released.
It refuses to run with a cluster transport environment set. It shows nothing
about membership, transport or generation.

## Two-rank transport check

Each Mac needs RDMA enabled (`rdma_ctl status`), an active port
(`ibv_devinfo`), and **an IPv4 address on the Thunderbolt interface itself**.
A port that only belongs to the Thunderbolt Bridge publishes no IPv4-mapped GID
and JACCL refuses it. Both Macs read the same device matrix: row *i*, column *j*
is the device rank *i* uses to reach rank *j*.

```sh
# matrix.json on both Macs, for example: [[null,"rdma_en7"],["rdma_en6",null]]

# Rank 0 listens on the coordinator address; start it first.
JACCL_RANK=0 JACCL_IBV_DEVICES=/abs/matrix.json JACCL_COORDINATOR=RANK0_LINK_IPV4:PORT \
  darkbloom-cluster-collective-check --mode raw --max-mib 64

JACCL_RANK=1 JACCL_IBV_DEVICES=/abs/matrix.json JACCL_COORDINATOR=RANK0_LINK_IPV4:PORT \
  darkbloom-cluster-collective-check --mode raw --max-mib 64
```

`--mode raw` calls the MLX C API directly; `--mode wrapper` drives the same
transport through the runtime's `Collective` type. Each rank prints one JSON
report and exits 0 only when both ranks saw zero mismatches. A pass shows the
strict backend initialized and carried the bytes correctly; it does not by
itself show which device carried them. Record that separately, for example by
comparing the payload volume with the interface byte counters.

A blocked native collective cannot be interrupted from inside the process, so
both products end on a fixed deadline (`--deadline-seconds` for the check, the
load deadline for the worker).

## Limits

- The worker accepts only the registered Qwen3.5 9B artifact, greedy text,
  one request at a time.
- The owner-authenticated JACCL bootstrap (`--bootstrap-socket-path`,
  `--bootstrap-owner-pid`, `--bootstrap-deadline-uptime-nanoseconds`) is parsed
  but refused: the pinned mlx-c does not carry the bootstrap bridge. Without
  those flags the worker uses the direct native bootstrap, where JACCL opens its
  own coordinator socket.
- `--prefill-schedule` accepts `serial_v1` and `one_chunk_lookahead_v1`;
  omission means serial. `--describe-runtime` advertises the supported
  schedules; capability metadata does not report readiness or available memory.
- Neither a worker build nor a pipe fixture qualifies remote ownership, model
  correctness, external TTFT, or production serving.
