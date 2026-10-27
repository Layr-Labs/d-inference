# Gemma framework checkpoint — 2026-09-13

Goal remains ACTIVE. The preceding interrupted goal turn was progress: common
Qwen/Gemma adapters, unequal shard commitments and native Gemma execution were
implemented and produced new numerical evidence. This continuation confirmed
the prior live process exited successfully, completed remaining regression and
failure checks, and recorded the current implementation. No goal completion,
production deployment, service restart or network configuration change occurred.

Canonical goal: `../d-inference/docs/design/distributed-inference-goal.md`.
Primary outcome remains registered Qwen3.8 27B 4-bit at >=800 uncached 8K prefill
TPS (>=1000 stretch) on two M3 Ultra 256 GB machines, better than the best
eligible solo path, with correct continuation and opt-in product integration.
Gemma4 26B and Qwen3.5 35B MoEs remain reusable-framework requirements; a tiny
fixture does not redefine qualification.

## Current authoritative state

- Branch `feat/cluster-inference`, base `e4df336bc8399f4fd0a46d1207b594d2514f14f5`.
  Experimental work and goal/docs remain uncommitted. No commits or pushes.
- Current native binary SHA256:
  `0ce0c8862e964e229abf01891520bcab258bb49b1b3b064407339cac53291081`.
- One-shot bundle manifest SHA256:
  `8cb5179ac1888a8a2e1df5cd26fa50bd6552537f64cce588ead22c2dc8123c68`.
- Whole-model/persistent source archive manifest SHA256:
  `9f4939ad5733dadaeab1538428b5a4e1b5e63cbcc9139044577ad07363b0f785`.
  Rechecked code still matches; three existing documentation files changed and
  one experiment report was added after that snapshot.
- Current native report schema6, worker protocol2. Do not send version1 commands
  to this binary. Historical protocol1 reports retain their original snapshots.
- Submodules unchanged at the three commits recorded in the new experiment report.
- No native worker/build/validation processes remain. Sessions62733 and49106
  completed exit0; docs-check session50396 completed exit0. Do not restart them.

## Completed evidence

Public report:
`../d-inference/experiments/cluster/inference/GEMMA_RUNTIME_VALIDATION.md`.

1. Final native build passed (`gemma-framework-build-final-20260913.log`).
2. Gemma planning/storage pure checks:9158 accepted/26 rejected metadata checks,
   eight malformed storage commitments rejected including overlapping intervals.
3. Native protocol2:4112 accepted/91 rejected fixtures.
4. Whole Gemma matrix:16 logical executions/eight solo-versus-TP pairs. F32 four
   pairs pass strict bounds; BF16 four pairs remain NOT numerically qualified.
   Worst BF16 row relative RMS is0.2281704; one of32 BF16 teacher-history argmax
   rows differs. Both TP rank logits match exactly. No BF16 root cause proved.
5. Gemma persistent driver completed all eight cohorts,24 A/B/A requests and
   eight fresh one-shot controls. Exact within-plan cache isolation and fresh
   equivalence pass for both profiles/dtypes, solo/FFN.
6. Final current-binary direct-loader checks:both Gemma profiles times two
   metadata cases, plus Qwen MoE full partition times two metadata cases pass.
   The initial driver used invalid `loader-check` for Qwen; native rejected
   before loading. Corrected mode `loader-parity` passed; error retained.
7. Qwen current protocol regression:six cohorts/18 A/B/A requests/six fresh
   controls pass for tinyF32,qwen-moeF32,qwen27-headsBF16, eachsolo/full.
8. Actual native Gemma cancel:solo andFFN cancel after first callback, whole
   native cohort reaped, epoch unusable. Deliberately divergent peer prompts
   rejected before accepted/token. See `runs/gemma-native-failures-20260913`.
9. All137 Python tests had passed26.363s; final test receipt source hashes still
   match exactly. No redundant CPU suite rerun after documentation-only edits.
10. `git diff --check`, `scripts/docs-check.sh --all` pass (280docs). Public
    connection-identifier scan passes; native/runtime source archive unchanged.

Read-only48GB SSH probe still timed out at5s. This gives no distinction between
power-off, hang or lost networking. No network changes, recovery actions,
sustained real-model benchmarks or provider restarts attempted.

## Next meaningful work

The numerical gap merits diagnosis before another performance claim. Inspect
actual Gemma dense/sparse branch values and router outputs under controlled
histories. Do not infer that router changes explain the observed difference
without capturing them. Stored BF16 partial-output rounding and expert-weighted
sum rounding are candidate mechanisms. Casting only a finished BF16 local
result to Float32 cannot recover its already-lost precision.

Pinned API seam review: dense `QuantizedLinear` is open and supports direct
stored-array construction; `QuantizedSwitchLinear` and `SwitchLinear` are public,
not open, so external subclass replacement is unavailable. Their affine path
widens metadata when the incoming activation is Float32. Gemma's private typed
MLP/expert wrappers cannot be replaced with an arbitrary unary module. An
experimental wider-whole-FFN policy can instead wrap the open pre-FFN RMSNorm
to promote its result before all branch projections, retain Float32 through
expert weighting and collectives, and cast once before the corresponding
post-FFN RMSNorm. That is broader than down-projection-only precision and must
be named/documented honestly, compared with an identically configured solo
path and separately against ordinary BF16, and bound into plan/report identity.
This is a candidate design only; no such policy is implemented by this checkpoint.

Retain model-specific semantics and distinguish numerical improvements from
quality qualification. Wider precision can cost communication/compute and
should not become default without real-artifact quality and latency evidence.
The primary dense27B M3 Ultra target, actual hardware RDMA, real weight loading,
memory peaks, production CBv2 integration and opt-in setup/trust/rollback/recovery
are still open. The missing peer is not a reason to mark the goal blocked while
useful software work remains.

All three existing subagent followups failed at model capacity during this
continuation; root completed checks/docs locally. They performed no new edits.
