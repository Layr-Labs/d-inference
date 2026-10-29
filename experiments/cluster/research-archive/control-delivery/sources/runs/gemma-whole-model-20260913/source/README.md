# Cluster inference experiments

The governing objective and acceptance criteria are recorded in the
[active distributed-inference goal](../../docs/design/distributed-inference-goal.md).

This directory is an isolated development harness for evaluating inference plans
across connected Apple Silicon Macs. It does not register a provider, change the
model catalog, or serve network inference requests.

The Qwen comparison includes a single-node baseline, two-rank dense-FFN tensor
parallelism, and a broader partition of FFNs plus attention and recurrent heads.
Independent replicas are another launcher mode; pipeline and prefill/decode
placement remain future comparisons. This experiment does not select a
generally optimal plan or establish superiority over another engine.

## Inference experiments

The [native Qwen harness](inference/README.md) provides local partition and
loader correctness checks. The [inference launcher](runtime/README.md) snapshots
its runtime, verifies artifacts and supervises solo, replica or cooperative
runs. Explicit synthetic loopback examples exercise multiple processes on one
development Mac; their timing is not evidence of hardware cluster throughput.

## Transport calibration

The [native transport probe](transport/README.md) builds against the repository's
pinned JACCL source and requires macOS and SDK 26.2 or newer. RDMA must already be
enabled on both machines. The real backend must initialize a two-rank group;
there is no TCP data-path fallback.

Build from the repository root:

```sh
cmake -S experiments/cluster/transport -B experiments/cluster/transport/build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.2
cmake --build experiments/cluster/transport/build --parallel 8
```

`run_transport.py` uses existing SSH configuration, stages the executable into a
new `~/DarkbloomDev/cluster-runs/<run-id>` directory on each node, and starts both
ranks with a remote deadline. It does not install keys or change SSH settings.
Use two distinct aliases for two distinct machines. The coordinator argument is
an unused TCP port on rank 0's reachable IPv4 address; this connection exchanges
setup information. Tensor data uses the configured Thunderbolt RDMA devices.

For example, replacing the aliases, devices and documentation-only IP address:

```sh
python3 experiments/cluster/run_transport.py \
  --host mac-a --host mac-b --device rdma_en1 --device rdma_en1 \
  --coordinator 192.0.2.10:43197 \
  --binary experiments/cluster/transport/build/cluster-transport-probe \
  --output /path/outside/repository/transport-run --timeout 90 \
  -- --mode both --warmup 5 --repetitions 100
```

The output directory must be new and outside the repository; the launcher
resolves symlinks before enforcing that boundary. It contains each rank's JSONL
and stderr plus a run manifest with the binary SHA-256, effective arguments and
exit codes. These records include private machine names and addresses. The
launcher snapshots the binary once and verifies its SHA-256 on both remote
machines before either rank starts, so concurrent local builds cannot change
the executable associated with a run. Remote staging directories remain for
inspection.

Each remote supervisor kills its benchmark process group at the deadline and
on SIGHUP, SIGTERM or SIGINT. The native probe also has an independent alarm,
forced to the smaller of the launcher timeout and any supplied
`--timeout-seconds` values. If the SSH session or supervisor disappears without
running its cleanup handler, that alarm still bounds an initialized probe.
Local interruption can leave a rank running until one of those deadlines;
these mechanisms do not claim instantaneous cleanup across a broken network.

Successful process exits alone are insufficient evidence. Inspect both ranks'
completion records and every measurement's correctness field. Compare the same
payload size and dtype. `payload_GBps_at_median` divides payload bytes by observed
time; it is neither aggregate bidirectional bandwidth nor a model TPS result.
The Metal mode includes GPU command submission and completion fences around the
collective. JACCL still uses registered internal staging buffers, so this does
not demonstrate direct zero-copy GPU RDMA. See the probe documentation for timing
boundaries and per-rank versus paired-sample statistics.

## Measurement requirements

Record the model artifact hash, executable hash, plan, dtype, prompt and decode
lengths, prompt chunk size, batch width and generated token IDs. Exclude loading
from steady-state TPS and report it separately. Use fresh prompt state for
uncached-prefill comparisons. Count accepted target output tokens for decode;
cached prompt tokens and speculative proposals are separate metrics.

Compare the same artifact and workload on each node and on the pair. Verify
numerical correctness before interpreting speedup. Note background workloads,
power mode, thermal state, memory pressure and swap changes. Report per-request
latency separately from aggregate throughput. A two-node result is useful only
against the best eligible single-node or independent-replica baseline for the
stated objective.
