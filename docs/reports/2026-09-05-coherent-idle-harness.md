# Coherent benchmark idle observations

> Last updated: 2026-09-05 · commit `26204c759`

The benchmark now waits for published retirement at known idle boundaries,
preserving the actual last tuple on timeout or cancellation. Eight focused Swift
tests and the standalone release build pass. Fresh paired model runs are still
required; this change does not relabel the earlier Qwen3.6 observations.

## Change

Native terminal delivery can precede publication of retired engine gauges.
The original harness combined these old gauges with already-refunded process
accounting and failed the strict idle gate in some cold control requests.
`BenchmarkIdleObservation.capture` polls immutable session snapshots with
cooperative yields and a five-second monotonic deadline. It never refreshes
native gauges, advances a model step, or substitutes a later tuple in old evidence.
The timeout bounds polling; the current non-I/O snapshot call is still awaited.

Sampling runs after serial completion, after the entire concurrent batch, and
after shutdown. Concurrent request rows retain immediate observations. Request
TTFT/decode/elapsed/cleanup timestamps and whole-batch elapsed time stop before
observation, which has separate timing, attempt count and status fields.

Normal idle requires retired requests, zero live/promised pages and drained SSD
stage/write-host reservations. Admission reservation may equal reusable physical
backing. Shutdown additionally requires zero native backing/segments and zero
process owners, closing owners, charges, materialization and promises. Logical
address capacity, model weights, allocator cache and RSS need not disappear.
Timeout/cancellation fails the row or enclosing report without losing outputs;
a later successful shutdown sample cannot erase the earlier failure.

## Validation and artifact

The seven-path harness patch is
`58dd9167691ecd22c644ea05142cd1c771e1090b73a5819e02156f1c577e4710`.
Eight tests cover stale-to-idle publication without additional steps, timeout
with the final tuple, idle arriving after the deadline, cancellation, reusable
backing, missing/live page state, shutdown owners, and both SSD host-reservation
paths. All eight pass, with zero failures or skips. The test command took
328.79 seconds; the separate release build took 251.16 seconds.

The wrapper initially rejected Swift Testing's current summary wording despite
all eight named passes. Its failure, original execution record and raw log are
preserved. The addendum verifies every passed name against the eight declarations;
no test rerun or source correction was made to obtain the pass.

New standalone probe SHA-256:
`eee66c9aaefa1b01dc696c551f8b98e7e89515b9389f4d53324c2302ccd3fa11`.
Both new paired arms must use this binary. The production CLI is unchanged.
Provider sources retain the prior diagnostic SPI; native and MLX dependencies
remain unchanged. Root verified all 41 build payloads, seven runtime artifacts,
677 provider inputs, actual test/release graph source hashes, raw named passes,
and exact equality of all seven applied source files with validated snapshots.

The [manifest](evidence/coherent-idle-harness-2026-09-05/manifest.json) and
[archive](evidence/coherent-idle-harness-2026-09-05/payloads.tar.gz) retain
56 payloads totaling 1,977,462 bytes. They include the frozen source candidate,
build/test logs and graphs, original wrapper failure, artifact hashes and root
review. Compiled artifacts are excluded.

Manifest SHA-256: `02ca26ddf0ae51236b0ee317e1f177ed5d8d26278a9d3ab0d6a0383f6dd1d68b`.
Archive SHA-256: `ee4facb9fad3333310aa3e321c810b1b1373c4640eaeabd063a0475fe9bdc24a`.

Related: [original Qwen3.6 evidence](2026-09-05-final-cache-evidence.md),
[benchmark procedure](../developer/test.md#prefix-cache-benchmark-validation).
