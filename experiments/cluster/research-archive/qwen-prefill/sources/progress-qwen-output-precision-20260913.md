# Dense Qwen output precision progress — 2026-09-13

Goal remains active: at least 800 uncached prefill TPS (1,000 stretch), batch
one / 8,192 prompt tokens, exact registered Qwen3.8 27B 4-bit on two M3 Ultra
256 GB machines with their GPU counts recorded. This checkpoint improves
numerical diagnosis and adds bounded actual 9B evidence; it does not qualify
distributed performance.

Repository: `/Users/developer/DarkbloomDev/d-inference`, branch
`feat/cluster-inference`, base `e4df336bc8399f4fd0a46d1207b594d2514f14f5`.
Canonical goal: `docs/design/distributed-inference-goal.md`.
Current public record: `experiments/cluster/inference/QWEN_OUTPUT_PRECISION.md`.
Previous frozen record: `experiments/cluster/inference/CBV2_VALIDATION.md`.

## Implemented and verified

- Added explicit dense-Qwen FFN down-projection precision, default native.
  Float32 input/multiply/reduction casts back once to incoming dtype. Shared
  quantized output implementation preserves actual MLP dispatch and packed
  parameters. Preflight rejects unsupported models and duplicate wrappers.
- Report schema 9, worker protocol 5 and plan identity bind the new policy.
  Python forwards and validates it separately from Gemma whole-branch policy.
- Added bounded same-hidden final norm/head shape diagnostic. It performs one
  ordinary prefill and reuses evaluated hidden state and actual head tensors;
  there is no numeric acceptance assertion or throughput measurement.
- 78 matrix executions independently audited: both-wide BF16 FFN TP 6/6 exact,
  full TP 5/6 exact. The remaining full-TP seed 31 prompt 96 first-row gap has
  relative RMS .00547284137; all seven teacher decode rows are exact. This
  residual cannot be explained by ordinary/CBv2 narrowing because both sides
  use the same CBv2 schedule. FFN-only FFN TP passes 5/6. Every nonnative solo
  policy changes two of 48 synthetic argmax choices from native. No gate relaxed.
- Four F32 TP comparisons pass; same-mode native/both-wide F32 output is exact.
  Six previous native BF16 solo/TP controls reproduce exactly.
- Twelve synthetic same-hidden checks isolate head-shape effects at final
  width 32, with exact norm output. Matched qwen27 full/narrow head hashes
  reproduce earlier ordinary/CBv2 first-row gaps. Widths 1/2 match exactly.
- Six bounded real registered 9B solo calls complete. All 12 artifact files,
  6,113,952,230 bytes, freshly hash to aggregate
  `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.
  The 96-token head diagnostic changes 100,298/248,320 logits with maximum absolute error .125,
  relative RMS .00215441019, and exact normalization. Head hashes reproduce
  ordinary/CBv2 first-row outputs; the following three native decode rows match.
  Wider policies change all four rows, though argmax stays [4087,13,271,1206]
  in this one short fixed-history sample. All six four-row comparisons fail
  the strict gate. These are policy departures, not real TP comparisons.
- Real9B peak active MLX bytes are 5,265,031,082 ordinary native;
  5,283,110,656 CBv2 native; 5,519,546,102 FFN-wide; 5,609,991,782 both-wide.
  Peaks reset after load and include resident buffers/request allocations,
  excluding the earlier load transient, allocator free cache and host/RSS.
- Six persistent both-wide cohorts / 24 requests pass repeated-A and six fresh
  controls, stable one-load identities and zero decode for one output.
  Cancellation reaps/fences solo/FFN/full epochs; command mismatch rejects
  before acceptance and precision mismatch before readiness. Six extra native
  CLI exclusions reject before MLX/model initialization.
- Release build passes,173 CPU tests pass, 75 native operator records contain
  two exact new FFN checks, and native protocol passes 4,112accepted/97 rejected.
  Operator record count includes intentional numerical diagnostics.
- Final source/binary verification passes; only documentation changed after
  the matrix source snapshot. Docs check 280 files, public scan 137 files,
  pinned submodules clean. No native inference/transport jobs remain.

## Identities and audit caveats

Binary SHA256:
`74ab08e0d55dbb00b7f5603ec7b686ef7dab2021fcdc790bc816d29c03b3fcb1`.
Matrix experiment-source manifest:
`32acc8968a811f39bf7c0be9d401d93b633d4f6e38c5f7ac54e71a9e1107f964`.
Protocol 5 canonical fixture:
`d269b0584795c3542a1524afbd01e57dea67e58402716c0474a8d30cd78177c6`.
Final records:
`qwen-output-precision-final-verification-20260913.json` and
`qwen-output-precision-final-source-manifest-20260913.json`.
CPU-only replay script: `verify-qwen-output-checkpoint-20260913.py`.

Raw evidence uses `runs/qwen-ffn-output-*-20260913`,
`runs/qwen-output-boundaries-20260913` and
`runs/qwen9-output-boundaries-20260913`. Independent matrix and synthetic
head audits live inside their run directories. Actual 9B independent audit is
`qwen9-output-boundaries-independent-audit-20260913.{md,json}`.
The worker/failure audit is
`runs/qwen-ffn-output-workers-20260913/independent-worker-failure-cpu-audit.json`,
SHA-256 `0d86e0eadabe0aa8f88c9c5d84a7cb92dd902c7245f2b98698413476e60cc6de`.
Its raw replay verifies 40 rank completions, 290 frames and 97,280 logit values.
Historical process reaping remains the original driver's observation, supported
by terminal failure manifests and saved frames. The six extra CLI exclusions
retain summarized outcomes and matching source guards, without separate raw
stdout/stderr evidence.
The separate schema annotation erratum is
`runs/qwen-ffn-output-failures-20260913/report-schema-erratum.json`, SHA-256
`9c944f59aa717c4718655fb47479e4889fa9c1c419a89ba5f7d163ecda928736`.
All ten actual fresh reports are schema 9; archived validation rejects schema 8
mutations of all ten.

The original failure driver's receipt has stale report_schema_version 8 metadata;
actual worker protocol is 5 and tested binary report schema 9. Preserve original
evidence and the separate audit erratum; no schema 8 inference report was
accepted by this failure exercise. No native rerun is needed for this annotation.
Final source inventory additionally includes two existing .gitignore files and
docs outside the matrix's archive scope. No new executable source appears.
One final auditor initially assumed those unarchived dotfiles were new code;
corrected inventory classification without changing execution evidence.

Solo native reports may retain throughputMeasurementValid=true because capture
is outside their timers. All run manifests/receipts explicitly decline hardware
performance qualification. F32 audit errors reconstructed from IEEE754 values
differ in trailing digits from calculations on JSON decimals; outcomes agree.
The unchanged public Docker image namespace is a scanner exception verified
against base Git contents, not a leaked credential.

## Next work

The reviewed implementation proposal is
`verified-local-correctness-proposal-20260913.md`, SHA-256
`682365f4fb2a17a7a58d280212d1611aa841ee5b318f4d142f8810d5eecc57a8`.
It is a source-only proposal; no real-model loopback guard has been changed.

1. Move from synthetic TP and actual-model solo diagnosis to a deliberately
   bounded actual 9B local TP correctness path. Preserve existing real-loopback
   rejection by default; require an explicit opt-in, pinned manifest/config,
   short finite prompt/output, teacher history, logit capture, one measured
   repetition, no warmup, finite timeout, two local ranks and adequate memory.
   Mark every such run correctness-only and ineligible for throughput. Exclude
   persistent workers until their repeated-request bounds have a separate design.
   Prefer reusable artifact/capability validation; fixture-specific pins belong
   in the validation driver. Do not silently remove the real-weights guard.
2. For the first actual 9B paired test, compare native and both-wide matched
   solo/FFN/full modes, bound token count and initially use one prompt. Inspect
   identity, byte selection, effective dtype, memory and raw continuation logits.
   Keep native-policy departures separate from same-policy TP differences.
3. Isolate the remaining synthetic full-TP first-row gap if it also matters on
   real weights. Continue toward actual target shape and useful operator
   profiling; avoid growing synthetic matrices without a new causal question.
4. The registered 27B local directory contains metadata only; 11 files totaling
   16,320,199,553 bytes are absent. Other cached27B artifacts are different and
   cannot substitute. Local free disk is about 164 GiB. Download exact registered
   bytes when needed for the next controlled correctness/performance stage.
5. The 27B output_gate_type=swish source audit resolves the earlier semantic
   concern: pinned GDN RMSNormGated already uses SiLU/swish after norm. The
   separate full-attention sigmoid gate must remain unchanged. The production
   apple_m5/mlx_nax eligibility gate remains unchanged; inspected rollout history
   does not establish an M3/M4 math incompatibility, but actual qualification is
   still required. See `qwen38-output-gate-and-eligibility-audit-20260913.md`.
6. Latest read-only 48 GB SSH attempt again timed out; power, freeze and network
   causes remain indistinguishable. No interface/network changes. Continue
   periodic availability checks without sustained physical tests until it returns.
7. Production scheduling/paged integration, state handoff, physical TB/RDMA,
   M3 Ultra qualification and opt-in setup/trust/rollback remain open. Goal is
   active, not blocked: useful local work remains.

Root is the sole native/GPU orchestrator; agents perform CPU source reviews,
driver preparation and evidence audits. No commits, pushes, deployments,
provider restarts, remote service starts or network mutations occurred.
