# Allocator footprint and native paged ownership

> Last updated: 2026-09-05 · commit `69a75de82`

Native paged allocation now reserves the allocator's per-buffer upper bound
before construction and settles to measured backing bytes after evaluation.
Logical page geometry remains separate from allocator padding and cached-buffer
reuse. This closes the foundation's logical-bytes pricing gap; provider and
complete SSD integration still require their own validation.

## Behavior verified

`Memory.allocationFootprintUpperBound(byteCount:)` covers one allocation under
existing rounding and cache-reuse rules. It does not reserve a buffer or price
an entire graph. `MLXArray.evaluatedBufferInfo()` reads available backing
metadata without evaluating or waiting. Only the fresh, exclusive full segment
owner can turn its observed allocator bytes into materialization coverage;
rebased wrappers share that owner. Growth and checkpoint adoption preserve the
full request promise, rollback identity and release-before-refund ordering.

An external diagnostic found an additional `Data` reference after `eval` in all
100 tiny observations; synchronizing the captured stream removed it. A retained
shared view continued to prevent uniqueness. Fresh segment construction now
drains that stream after successful or throwing evaluation before its ownership
check or failed-allocation refund. The metadata getter remains non-waiting.
Diagnostic synchronization timings are not model-overhead measurements.

## Validation

| Scope | Result | Evidence basis |
|---|---|---|
| Native admission, paging, checkpoint, runtime dtype, recurrent/MTP and parity filters | 322 functions / 404 cases pass across 29 filters; zero failures or skips | Final foundation6; build 56.40 seconds |
| Swift allocator wrapper and metadata | Four functions / four cases pass | Foundation3, unchanged dependency inputs carried forward |
| C++ allocator bounds, prediction and cache regression | Three cases pass on CPU and three on Metal | Foundation1, unchanged C/C++ inputs carried forward |

Runs used Apple Silicon, macOS 26.4 and Swift 6.3.2. The final source proof covers
35 owned files, 455 native inputs and 1,356 dependency inputs, with no drift.
Committed source pins are native `a486a55d032deae001190bf9795ece1cb3d9a609`,
Swift `2814c8ad5c2858b74bd364977bc1a59844621af8`,
MLX `c31408ca889ee70ef433d708a24f71b33f3a06f6`, and
mlx-c `1cff8fd14a73cb1f80b9bbb0a1ff2301bbfd1891`.

## Preserved corrections

Attempts 1–4 preserve the missing Foundation import, fresh-ownership diagnostic,
success/failure completion fence, and throwing-getter test-macro corrections.
Attempt 5 built but failed three filters: an integer-index gather was incorrectly
used as a shared-view fixture, and older grant/parity fixtures assumed logical
bytes equaled allocator commitments. The final tests use a contiguous full-size
reshape for sharing, release unexpected rows before assertions, and price each
known backing independently. Exact page, refusal, epoch, reuse and token-parity
assertions remain. The failed aggregate is not counted as a passing run.

## Evidence and limits

The [manifest](evidence/allocator-footprint-2026-09-05/manifest.json)
(SHA-256 `0927b8d09c172d2d738135e073f0dde631748feb71d8eb56efaacf9d2aaaac15`)
and [archive](evidence/allocator-footprint-2026-09-05/payloads.tar.gz) preserve
344 verified payloads: final evidence, attempts 1–5, the external diagnostic,
original source freezes, exact source archives, compiler graphs and commit
verification. Archive SHA-256 is
`440ea3e54f95cde39ce667b648d0bb8c4b8f022e2e6b48a7bc86d6526c7f7a9a`;
final validation manifest SHA-256 is
`1028f760d648cae2161f81b0a1be7c9250bca9e39ba7ce44f91dbaac00d5dc4e`.
Build products and model weights are excluded.

CUDA is unexecuted. The detached allocation-policy API is not part of this
validated source. Native process-owner fakes verify charge/coverage transitions;
real provider coherent allocator accounting, complete SSD codec integration,
recurrent/assistant allocation coverage and whole-graph scratch remain separate
gates. No fleet-model latency, capacity gain, cache default or rollout change is
claimed. Current mechanisms are documented in
[hardware support](../architecture/hardware-support.md#process-ownership) and
the [MLX stack](../architecture/components/mlx-swift.md#allocator-footprint-and-backing-ownership).
