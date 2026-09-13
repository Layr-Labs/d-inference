# Useful output budgets for speculative decoding

> Last updated: 2026-09-05 · commit `089d9ade3`

The common MTP planner now prevents draft work that cannot produce additional
output before the request limit. All 126 selected native tests pass. This is
an independently justified optimization; normal Qwen3.5 model parity and real
performance with the changed planner remain unproven.

## Change and original evidence

A depth-k verification consumes the confirmed carry and k draft inputs, computes
k+1 target outputs and can emit at most k+1 new tokens. With R output slots left,
only R-1 draft positions can provide useful extra output. The old common bound
allowed k=R when a valid carry existed. Normal Qwen marginal policy already used
R-1, but exploration bypassed that policy and fixed-depth offers did not use it.
A final-slot exploration could therefore verify two positions to emit one token.

`EngineLoopV2.mtpDepthWithinOutputBudget` applies the R-1 bound to every offer
after marginal selection and before step/KV reservation. The shortest eligible
row continues to bound the common rectangle. Existing `tail_depth` telemetry
records the clamp. Carry validity, persistent history, synchronized seeding,
recurrent state, rollback and final emitted-token limits are unchanged. This
common bound applies to Qwen and Gemma MTP on contiguous and paged storage.

The original exact Qwen3.5 paged cache pair had a normal adaptive mismatch in
token 32: `944` versus `19549`. The prepared prompt and preceding output IDs
matched. Differing request histories used different seed/rectangular schedules,
and the source permits numerical differences between rectangular and serial
verification. Those observations suggest a shape-dependent cause; they do not
prove identical internal logits or exclude a cache-state defect. No same-logits
reducer trace was captured. The failed gate and original source audit remain
in the evidence, and the new bound does not waive them.

## Validation

Native commit: `a932d38cee0beca41ca1a0e71c1e867913a65353`.
The two-path delta contains one common helper/planner correction and five new
policy tests. The tests use actual exploratory/fixed controller offers, mixed
B1/B2/B4 remaining budgets, existing offer caps and empty/exhausted/extreme
budgets. Eight existing MTP groups cover controller cadence, Qwen stateful
history, capture/verification, engine parity, round execution, KV staging and
rectangular degradation.

The build took 66.66 seconds. All nine groups pass: five new tests and 121
existing tests, with zero failures/skips and no source or fixture corrections.
Capture/verification contributes 12 XCTest cases; its separate zero-test Swift
Testing summary is not the suite count. Eight prior baseline logs are retained.
Root verified raw individual passes, all 54 validation payloads, 481 native and
1,356 dependency source hashes, and the actual compilation graph. The only
compile-only package delta replaces the remote MLX dependency with its exact
pinned local path. Applied native sources match the tested snapshots.

The [manifest](evidence/mtp-output-budget-2026-09-05/manifest.json) and
[archive](evidence/mtp-output-budget-2026-09-05/payloads.tar.gz) preserve
109 payloads totaling 4,252,459 bytes, including the original Qwen3.5 audit and
failed model evidence, source candidate, unit logs/graphs and root review.
Compiled artifacts are excluded.

Manifest SHA-256: `cd6d3c03463758aec8befc1f03f04e9d259e1e0c27c50d973b4d4f367eea73e5`.
Archive SHA-256: `7161a56dc1357e7e659ccdceaac8bff99971812865779efc4659adfb4e5e770f`.

## Remaining model gate

A distinct serving probe must combine this native source with the
[coherent observation harness](2026-09-05-coherent-idle-harness.md).
Repeat the normal-MTP Qwen3.5 cache-off/SSD pair at 32 and 128 output tokens so
the previously divergent position is also tested inside a longer sequence.
Preserve strict output, isolation, cancellation, retirement and backend checks.
No decode speedup, full five-model acceptance, default promotion or production
CLI deployment is established by this unit milestone.
