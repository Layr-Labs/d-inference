# Two-Mac transport probe

> Last updated: 2026-09-14 · commit `e4df336bc`

This standalone experiment measures the pinned MLX JACCL implementation without
building MLX or loading a model. It requires two Apple Silicon Macs connected by
Thunderbolt, RDMA enabled on both, and macOS / Xcode SDK 26.2 or newer.

An actual host-buffer smoke on two M4 Pro Macs passed on 2026-09-15 UTC with
`float32`, zero warmups and one repetition: both ranks completed, all five payload
sizes from 10 KiB through 20 MiB were correct, and stderr was empty. The temporary
interface address used for that run was removed afterward, with bridge and
management routing preserved. This establishes the narrow physical collective;
GPU staging, sustained bandwidth and model throughput require separate checks.

From the repository root:

```sh
cmake -S experiments/cluster/transport -B experiments/cluster/transport/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.2
cmake --build experiments/cluster/transport/build --parallel 8
```

The build reads `libs/mlx/mlx/distributed/jaccl/lib` from the pinned submodule and
downloads JACCL's pinned nlohmann/json dependency. No submodule source is changed.
The resulting `cluster-transport-probe` executable needs no separate metallib: the two
tiny Metal kernels compile at startup, outside measurement.

Create an identical device matrix on both Macs, using each machine's actual
active RDMA device. For a link using `rdma_en1` at both ends:

```json
[[null, "rdma_en1"], ["rdma_en1", null]]
```

The underlying interface (for example `en1`), in addition to being active, must
have an IPv4 address so `ibv_devinfo -v` exposes an IPv4-mapped GID for that RDMA
device. A link-local IPv6 address on `bridge0` alone is insufficient for this
JACCL revision. Verify the device's GID before launching; network configuration
belongs to machine setup, not this benchmark.

Start rank 0 and rank 1 concurrently. Each process needs `JACCL_RANK` (`0` or
`1`), `JACCL_IBV_DEVICES` (local matrix path), and `JACCL_COORDINATOR` (rank 0's
reachable IP and unused TCP port, e.g. `$RANK0_IP:29570`). The TCP connection
exchanges setup metadata and currently requires an **IPv4** address; benchmark
payloads use RDMA. Keep private addresses
and result files outside this source directory.

```sh
./experiments/cluster/transport/build/cluster-transport-probe --mode both --dtype bfloat16 --warmup 5 --repetitions 30 --timeout-seconds 120
```

Both ranks must have the same build, device matrix, mode, warmup, and repetition
count, and dtype. `--dtype` accepts `float32` (default) or `bfloat16`; benchmark
both because CPU reduction cost can differ at the same byte count.
`JACCL_RING=1` selects JACCL's ring; leave it unset for mesh. The equivalent
MLX environment variable names also work. The probe rejects a world size other
than two and validates numerical rank values. A process timeout exits 124;
configuration, GPU, or correctness failures exit 1. A successful run has a
`complete` JSON record and exit status 0 **on both ranks**. If one rank fails,
the other may wait until its timeout; terminate the peer process if needed.

## What is measured

Each rank emits JSON lines for exactly 10 KiB, 1 MiB, 5 MiB, 10 MiB, and 20 MiB
of payload with the selected dtype. Both modes perform an out-of-place sum across two ranks.
Inputs are small, deterministic, and independent of the previous iteration, so
repeated sums cannot overflow. Every output element is checked after every
warmup and timed iteration. Output poisoning and CPU validation are outside the
timed interval, as is the per-iteration RDMA barrier.

- `host`: CPU buffers already contain input. `collective` times the blocking
  `all_sum` call; `total` also includes timer and empty producer/consumer calls.
- `metal`: a GPU kernel writes a shared input buffer, the CPU waits for its
  command buffer to finish, JACCL sums into a separate shared output buffer,
  another GPU kernel consumes the sum, and the CPU waits for that kernel.
  `total` includes command encoding/submission, both GPU kernels, both completion
  fences, and the collective. `collective` isolates time inside `all_sum`, which
  can include waiting for the other rank's GPU producer. The consumer writes a
  third shared buffer; all its elements are also checked by the CPU.
  GPU input and consumed buffers are poisoned before each iteration, outside
  timing, so stale contents cannot satisfy the correctness checks. BF16 kernels
  use explicit bit conversions for these exactly representable values; they do
  not depend on native GPU BF16 arithmetic.

JACCL uses its own preregistered RDMA staging buffers and performs CPU copies and
reductions. Passing Metal shared memory **does not make this zero-copy GPU RDMA**.
The Metal kernels are deliberately trivial; this is a transport/fence probe,
not a model, matrix-multiply, or tensor-parallel inference benchmark.

Statistics report median (midpoint for even counts), nearest-rank p95, minimum,
maximum, and decimal payload GB/s (`bytes / elapsed_seconds / 1e9`). This is
logical all-reduce payload throughput per rank, **not aggregate send+receive
wire bandwidth**. It includes the library's reduction/copy overhead.
`rank_max_total` and `rank_max_collective` first take the maximum of the two ranks
for each paired repetition, then summarize; this approximates the synchronized
critical path without adding the barrier's own latency. Raw per-rank samples
include producer/consumer wall time to allow additional analysis. Do not add
component medians to estimate the total: they need not be the same iteration.

Allocation, initial RDMA registration/setup, GPU compilation, and the TCP setup
channel are excluded. Long-term thermals, concurrent inference, real GEMM/GDN
work, and communication/computation overlap require subsequent experiments.
The default sweep is bounded and normally takes seconds; 30 repetitions give
only a rough tail estimate. Increase repetitions for a more stable p95.

## Local checks without RDMA

`--self-test --dtype bfloat16` (and separately `--dtype float32`) runs the real
host/Metal producer and consumer code for every size, sums both synthetic ranks
on the CPU, and checks every element. It emits `local_self_test` records with
`rdma_tested: false` and no performance measurements. No environment variables
or peer are needed. This verifies buffer logic and GPU compilation, not the
distributed path; both-rank correctness runs are still required.
