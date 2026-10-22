# Bounded real-model correctness on local loopback

Prepared from source and existing receipts only, 2026-09-13. No code changes,
native builds, MLX calls, GPU execution, or transport changes were performed.

Use an explicit generic `local_correctness: true` opt-in in the one-shot run
specification, with matching native `--local-correctness` and
`--artifact-aggregate-sha256 HEX`. Keep the existing `loopback-test` backend and
its localhost-only ring implementation. Real loopback without the new opt-in
continues to fail. The runtime verifies the explicitly requested artifact and
enforces fixed resource limits; the external validation driver pins the first
registered 9B artifact. This keeps model registration identifiers out of the
reusable runtime.

The first implementation should support only the existing dense Qwen adapter.
The generic opt-in is not a promise that every model family is qualified. Model
family, exact configuration, partition plan, storage layout, dtype, and execution
path must pass their existing checks. The first external fixture pins:

- Model: `Qwen3.5-9B`, locally at `~/DarkbloomDev/models/Qwen3.5-9B`.
- Aggregate SHA256: `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.
- Configuration SHA256: `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`.
- Prompt: the saved natural-prose 96-token prefix, SHA256
  `4c1f00887775d26c29e398bc54e2b37501614599455df2f3b83c5544608b3612`.

The opt-in should be legal only for two local, one-shot `ffn-tp` processes using
`loopback-test`, real weights, and the same explicitly verified manifest
aggregate. It must reject synthetic weights, SSH locations, JACCL, solo/replica
backends, persistent workers, routing replay/capture, Gemma diagnostics, and MTP.
Both `ffn` and `full` partitions already have compatible Qwen loaders and
reduction adapters. Use matched execution paths and arithmetic policies for
each solo/TP comparison.

Recommended fixed limits for the first implementation:

| Resource | Limit |
| --- | --- |
| Ranks | Exactly two local processes; ranks 0 and 1 |
| Listener addresses | Existing two distinct `127.0.0.1:port` endpoints |
| Prompt | 1–128 actual token IDs; token file required |
| Chunk | 1–32 tokens |
| Output | 1–4 tokens; teacher file required when output > 1 |
| Capture | Full logits required; output × vocabulary ≤ 1,048,576 per rank |
| Repetitions/warmups | Exactly one / zero |
| Runtime deadline | At most 180 seconds; initially 170-second inner bound and 180-second outer cleanup bound |
| Verified manifest payload | At most 8 GiB |
| Canonical text tensor payload | At most 6 GiB |
| Selected stored tensors | At most 4 GiB per rank and 8 GiB across the pair |
| Largest selected host tensor | At most 512 MiB |
| Recycled MLX buffer cache | Consider 256 MiB per process, recorded in the diagnostic contract |

Check logical byte budgets from verified tensor descriptors and both ranks'
`PartitionStorageCommitment` before reading any selected tensor payload. Shape
and dtype checks still apply; byte caps do not replace them. A declaration in
the manifest is insufficient: retain `runtime.artifacts.verify_model` before
native launch and the native `VerifiedCheckpoint` descriptor/hash checks during
loading. Pass the expected aggregate into native verification so it is compared
before selected payload materialization. Comparing only the two ranks with each
other would accept two copies of the wrong artifact.

The main memory cost is replicated weights, especially embedding and LM head.
The existing verified metadata gives these exact stored-text payload estimates:

| Plan | Stored bytes per rank | Stored bytes across both ranks |
| --- | ---: | ---: |
| FFN TP | 3,679,087,104 | 7,358,174,208 |
| Full TP | 3,091,423,488 | 6,182,846,976 |

The complete canonical text payload is 5,038,041,600 bytes across 927 tensors.
FFN sharding covers 2,717,908,992 source bytes; full sharding covers
3,893,236,224. The largest selected tensor is a replicated packed embedding or
head weight of 508,559,360 bytes. `TensorDescriptor.read` owns a selected-sized
Foundation `Data` buffer and copies it into MLX storage, so budget one additional
largest-tensor host buffer per simultaneous reader. It does not retain a full
checkpoint tensor behind a sliced view.

At 100 positions, replicated attention KV plus GDN conv/FP32 recurrent state is
about 54.8 MB per FFN rank; full partitioning halves it. Pending generations,
temporaries, Metal resources, host output arrays, and optional Float32 metadata
caches add to this. Existing solo inference peaks are 5.265–5.610 GB, but those
are not loading peaks. A practical first attempt needs roughly 12–16 GiB of
available unified-memory headroom for the pair; this is a planning allowance,
not a measured guarantee. Retire the solo process before starting the pair.
Monitor both processes and system memory pressure; do not treat nominal RAM as
available memory. `Memory.memoryLimit` is a scheduling/backpressure threshold,
not a hard allocation cap. It must not be presented as a safety proof.

Implementation sequence:

1. Add the optional, strictly Boolean spec field and native flag. Preserve
   absence semantics for existing specs. Require the expected aggregate in the
   native opt-in. Put the resource contract in a small shared-purpose native
   helper rather than expanding `Main.swift` with checkpoint logic.
2. Update `runtime/configuration.py` validation and `rank_configuration`, and
   `Options.swift` validation. Check actual prompt/teacher lengths and captured
   logit product after parsing files, before inference. Validate inexpensive
   metadata and workload limits before collective initialization where possible.
3. Extend `VerifiedCheckpoint.swift` / `DirectShardLoading.swift` / the
   `ModelLoading.swift` call site to bind the optional expected aggregate and
   inspect the existing storage commitment before selected reads. Preserve
   independent owned storage, config-hash binding, file-change checks, full
   tensor-key coverage, and per-path quantization validation.
4. Add the opt-in and requested aggregate to `Main.swift` rank agreement.
   Existing agreement already binds actual aggregate, config, complete prompt,
   teacher presence/history, capture policy, dtype, precision, plan, and layouts.
   Keep `Collective.swift`'s ring availability and exact localhost checks.
5. Explicitly reject the opt-in in `runtime/persistent.py` before staging and
   native worker modes in `Options.swift`. `PersistentCohort` reuses ordinary
   spec validation, then accepts separately supplied requests; allowing it here
   would bypass one-shot bounds. Do not broaden worker protocol limits.
6. Update `runtime/reports.py` to require the opt-in's bounds, exact real artifact
   receipt, and existing non-performance flags. `Collective.correctnessOnly`
   already makes native `correctnessOnly=true` and
   `throughputMeasurementValid=false`. `runtime/cli.py` already excludes
   `loopback-test` from hardware throughput candidacy. Keep these unconditional.
   Existing report fields plus the saved spec can bind the opt-in without adding
   a new report field; a schema change is needed only if new telemetry is added.
7. Capture loading memory separately if making a loading-memory claim.
   `Benchmark.execute` resets `Memory.peakMemory` after loading, so its
   `peakMLXBytes` does not measure loader transients. Record pre-reset MLX
   active/cache/peak snapshots and process RSS separately, with clear labels.

Focused validation should preserve the existing test that real loopback is
rejected without opt-in. Add rejection tests for wrong/missing aggregate,
non-Boolean opt-in, nonlocal hosts, wrong backend/mode/family, oversized actual
token files, missing teacher/capture, excessive output×vocabulary, repeat/warmup
or deadline violations, and worker use. Reuse malformed hostfile, absent-peer,
rank-disagreement, and asymmetric-capture tests. Ensure an expected-aggregate
mismatch and byte-budget violation fail before selected tensor reads.

Then run the saved CBv2 solo baseline and one FFN pair, followed by one full pair,
sequentially. Use the same 96-token prefix, chunk 32, four outputs, and the saved
ordinary baseline's first three generated IDs as teacher history. Compare each
TP run to a solo run with the same CBv2 path and precision. Record all 993,280
logits per rank, finite checks, exact peer equality, per-row max-absolute and
relative-RMS differences, greedy agreement, and effective consumed tokens.
Retain strict numeric gate failures as findings rather than silently widening
tolerances. Native CBv2 should count 192 floating model reduction hooks per FFN
rank or 384 per full rank for this six-forward workload; this is a graph-hook
count, not independently timed transport completion evidence. Test the existing
Float32 output policies only with matched solo controls after the native pair.

Passing this phase establishes real-artifact local partition correctness and
request lifecycle evidence. It does not establish two-device throughput,
Thunderbolt/RDMA behavior, production scheduling, or the 27B performance target.
