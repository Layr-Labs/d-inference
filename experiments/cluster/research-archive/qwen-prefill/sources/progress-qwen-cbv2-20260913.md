# Dense Qwen CBv2 progress — 2026-09-13

Goal remains active. The target is at least 800 uncached prefill TPS (1,000
stretch), batch one / 8,192 prompt tokens, registered Qwen3.8 27B 4-bit on two
M3 Ultra 256 GB machines with exact GPU counts recorded. This checkpoint is
synthetic correctness and model/state integration progress, not qualification.

Repository: `/Users/developer/DarkbloomDev/d-inference`, branch
`feat/cluster-inference`, base `e4df336bc8399f4fd0a46d1207b594d2514f14f5`.
Canonical goal: `docs/design/distributed-inference-goal.md`.
Public evidence: `experiments/cluster/inference/CBV2_VALIDATION.md`.

## Implemented and verified

- Added explicit ordinary / cbv2-contiguous request execution, report schema 8
  and persistent worker protocol 4. Dense Qwen uses the actual pinned CBv2
  model adapter, contiguous KV, and committed request-owned conv/SSM state.
- Preserved concrete dense MLP types and output projection overrides. Dense
  MTP-off CBv2 supports these hooks; the earlier blanket fast-path concern was
  too broad. Specialized A3B captured MTP remains unsupported.
- Request geometry comes from each actual local model. Evaluate output, KV,
  offsets and recurrent roots; check MLX errors and state before commit;
  release ownership on close. Aggregate floating hook count is validated,
  without claiming a per-layer transport trace.
- 108 matrix executions / 180 native reports verified independently. Float32
  TP passes 36/36 comparisons, peak relative RMS 8.5733224e-7. BF16 fails all
  36 strict solo/TP comparisons, peak relative RMS .0151321352.
- Ordinary/CBv2 comparisons: 48/54 pass, 42 exact. Six BF16 failures affect
  only the first output when final prompt chunks contain 32 or 504 tokens;
  seven teacher-controlled decode rows match exactly. Widths 1 and 2 match.
- Nine persistent cohorts / 36 requests pass A/B/A isolation, stable model
  load identities, zero-decode single-output cases and nine fresh controls.
  An additional tiny/BF16 B comparison changes solo/TP argmax at positions
  3 and 4 for both FFN and full plans. This is a numerical qualification failure.
- Native cancel solo/FFN/full retires and reaps all workers/supervisors; epoch
  reuse fails. Native command mismatch rejects before accepted, path mismatch
  before ready, four unsupported CLI combinations before ready.
- Six Gemma historical ordinary-path cases across all three precision policies
  reproduce exact logits, model/input identity and token histories.
- Final release build passes; native protocol check 4,112 accepted / 95
  rejected; 162 CPU tests pass with all tested sources still matching.
- Docs check: 280 files OK. Whitespace/private-data checks pass for 130 public
  files; the existing public Docker base-image namespace is not a credential.
  Submodule worktrees are clean, only documentation changed after matrix
  source snapshot, and no native inference/transport jobs remain.

## Evidence and identities

Executable SHA-256:
`1a1cb598a53d07fceb8a589b49c7ef7a93bade685e33f79fcc7c1ac9c53d02b1`.
Main matrix experiment-source manifest:
`1283490fc23877e763323a63bb0a02746d3e42f900a6d954499d617a49a454f3`.
Final source/dependency/toolchain and validation receipts are in
`cbv2-final-verification-20260913.json` and
`cbv2-final-source-manifest-20260913.json` beside this checkpoint.
Independent audit: `cbv2-independent-audit-summary-20260913.{md,json}`.
Raw matrix, workers and failure evidence uses the `runs/cbv2-*-20260913`
directories. Successful Gemma regression evidence is directly under
`cbv2-ordinary-regression-20260913`, outside `runs`, because the archived
launcher infers its protected root from its relocated source path.

Retained failed harness attempts: 8,192 prompt plus eight outputs correctly
exceeds the synthetic 8,192 context; successful boundary run uses 8,184 plus
eight. The first archived Gemma replay location was refused before any native
launch by its output-directory guard. Neither attempt was silently excluded
from its own receipt or used as performance evidence.

## Next work

1. Isolate Qwen BF16 differences using the observed final-output shape seam and
   tiny persistent B divergence. Pinned CBv2 slices hidden before final norm
   and projection; this is a hypothesis, not a proven projection-only cause.
   Do not loosen numerical gates or equate agreeing peer ranks with solo parity.
2. Continue production scheduler / paged-backend integration only with explicit
   capability and ownership contracts. Current path is serialized model/state
   integration, without EngineV2 scheduling, prefix reuse, MTP or state handoff.
3. Recheck the offline 48 GB peer periodically using read-only SSH. Latest
   attempt timed out; network failure, power-off and freezing remain
   indistinguishable. No interface changes or service restarts were made.
4. Physical RDMA, real registered artifacts, target M3 hardware and opt-in
   setup/trust/rollback/recovery remain open. No sustained real-model benchmark
   was run while the peer was unavailable. Do not mark the goal complete or
   blocked: useful local implementation and numerical work remains.

Root remains the sole native/GPU orchestrator. Agents performed bounded CPU
source reviews, driver preparation and saved-result audits. No commit, push,
deployment, provider restart or network mutation occurred.
