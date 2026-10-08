# GDN input projection checkpoint — 2026-09-13

The active goal remains the registered Qwen3.8 27B 4-bit prefill target of
800 TPS (1,000 stretch), batch one / 8,192 uncached prompt tokens on two
M3 Ultra 256 GB machines, with exact GPU counts and fastest eligible solo
comparison. Additional models, decode behavior and opt-in release requirements
remain in `d-inference/docs/design/distributed-inference-goal.md`.
This checkpoint is substantive numerical/loader progress, not completion.

Repository `/Users/developer/DarkbloomDev/d-inference`, branch
`feat/cluster-inference`, base `e4df336bc8399f4fd0a46d1207b594d2514f14f5`.
Previous checkpoint: `progress-real-qwen-local-tp-20260913.md` (preserved).
Public record: `experiments/cluster/inference/QWEN_GDN_INPUT_VALIDATION.md`.

## Implemented and verified

New `qwen-gdn-input-check` mode runs one native-policy CBv2 chunk of 1–32
tokens, one output, zero warmups, one repetition, timeout <=180. Real input
requires exact artifact aggregate and actual token file. Synthetic dense
fixtures remain available. No worker, loopback collective, separate logit file
or other diagnostic is admitted. A separate schema1 diagnostic record leaves
ordinary schema9/protocol5 unchanged.

`QwenGDNInputAdmission` retains bounded config and token IDs, validates
dense/full-plan geometry and dimension/capture limits before MLX/model setup.
`BoundedProbeInput` extracts identical byte/integer parsing from the prior
local-correctness path. Its existing admission tests still pass.

`PreparedQwenCheckpoint` shares canonical sanitize/compose/quantization and
shape preparation with the existing partition loader. The new verified full
diagnostic loader hashes and pins complete artifact descriptors before reading
each canonical tensor; 8 GiB artifact / 6 GiB text / 512 MiB host-tensor limits
apply. Exact loaded shape/layout and equal-width BF16 conversion are checked.
This is reusable verified loading, not yet a stage/pipeline loader.

The capture replaces only first-layer RMSNorm, preserves its original weight
and epsilon, calls identical arithmetic, and retains output in a non-Module
holder. Normal CBv2 output/KV/conv/SSM roots finish, state commits and request
closes before inspecting the input. The norm is restored. GDN input projection
concrete classes are unchanged, preserving fusion eligibility. A scoped module
inventory is discarded before forward so it cannot keep all original weight
banks alive after native fusion creates aliases.

The diagnostic reconstructs full and both semantically selected `[qkv,z,b,a]`
projections after that normal forward. All use the same evaluated input,
full input K, affine W4/G64 packed weights and native floating dtype. Selected
Q/K/V/z/b/a ranges, raw values and hashes are reported. This is not a direct
capture of private fused output.

Build session15698 terminal0; binary
`c1fef9e4950fe067787943c07fdfb1f58e514b7ea4658ca89c136bb34aa7063b`.
Build log `qwen-gdn-input-build-20260913.log`. Existing package identity/exclude
warnings remain; one new unused try? result warning is harmless and retained
to avoid changing the tested snapshot after execution.

187 CPU tests pass, 37 Python sources unchanged. New native admission rejects
44 cases; adapter output has seven total records including prior checks.
Worker protocol still accepts4,112/rejects97. Four loader calls (dense/MoE ×
FFN/full) pass, each with F32 and F16-metadata conversion fixtures. Four separate
new dense-loader records compare every117 parameters against ordinary loading,
including bytes/dtype/layout, bad aggregate without mutation and compact owned
buffers after source corruption/deletion. No additional model forward is
used by the verified full-loader regression.

## Four native calls and numerical evidence

Run: `runs/qwen-gdn-input-20260913`, source snapshot157 entries.
Local M4 Max36GiB /14CPU /32GPU. Tiny F32/BF16 diagnostics, actual9B32-token
ordinary solo control, and actual9B32-token GDN diagnostic all exit0. Root
driver session23479 is terminal1 only because of the later Python summary bug
described below. No native job is still running in that driver.

Actual 9B remains aggregate
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`,
config `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`.
All12files/6,113,952,230bytes verified. Text927tensors/5,038,041,600bytes.
Prompt is first32 of prior96 IDs, not a substitute for previous96 logits.

TinyK128 fullN1028 → rankN514 is exact in F32 and BF16 (32,896 compared
projection values each). RealK4096 fullN12352 → rankN6176 differs in
125,801/395,264 values (31.827%), maxabs .25, RMS .007808625056073155,
relativeRMS .0026891772928119588. All12rank/component comparisons differ;
relativeRMS range .002480024388–.003086345910. Large orderedBF16step distances
near/crossingzero are not a model-quality measure.

Real captured normalized input SHA:
`4581989d3cfa6e0c6a65b17aa3b1f3e4c550085ad7ab6a99c460af68f3ba0f46`.
The diagnostic's full248,320 final logits equal the matched no-hook32-token
solo control exactly; argmax2018. This validates the combined loader/capture
path for this input. It is not a whole-model TP or continuation pass.

Sampled pressure2/no new swap across allfour calls; peak sampled ownedRSS
real solo4,181,262,336 / realdiagnostic5,783,322,624bytes. Planning headroom
7,729,163,878B includes extra512MiB forprojection/capture/JSON. Saved all-owned
cleanup and launcher reaping pass. These are observations, not hard memory caps.

## Bookkeeping failure and evidence preservation

Original driver SHA
`34f970701930c089d1713ef6efb0a56eea08363d1d3b896a9f6a99c8da7582af`
is retained in the run and
`validate-qwen-gdn-input-summary-failed-20260913.py`. After allfour native calls,
their cleanup, real source-byte checks and exact no-hook assertion passed,
line210 tried `dict(**comparison,exact=True,...)` although metrics already
contained `exact`. This raised TypeError. The original run receipt accurately
remains failed with the final call's bookkeeping status still `preflight`,
even though its saved native exit is0. Do not rewrite it as a successful driver.

The future external driver removes only the duplicate keyword, SHA
`8ad173873e3664e4ff4227b0b0d997d4e02582a3312369c060133dfe4ce8106c`.
Fix record: `qwen-gdn-input-driver-summary-fix-20260913.json`.
No inference reran for this correction. Separate CPU completion audit validates
the frozen raw evidence and records original failure separately from observed
native completion. Its raw-value oracle tests (11 cases) cover numeric/hash/
selection failures; they did not cover driver summary assembly.

## Next work

The first input projection is now a demonstrated arithmetic seam before any
conv/SSM/attention or collective operation. Pinned quantized.cpp dispatch
predicts splitK1 forN12352 and splitK2 forN6176 atM32/K4096. The intermediate
buffer uses input dtype. This is source-derived kernel reasoning, not a
captured dispatch trace or proof of the unique whole-model TP failure cause.

Next isolate this mechanism with the same evaluated input and stored triplets:
compare native versus F32 accumulation and cast-back, reporting BOTH full/rank
agreement and departure from original native. A useful orthogonal diagnostic
is padding selected output rows to originalfullN, then cropping; this preserves
native dtype and source-predicted splitK while changing no real selected rows.
Padding costs extra compute and is not itself a proposed performance solution.
Do not silently widen production projections or loosen the numerical gate.

Whole-layer prefill pipelining remains the other architecture candidate.
Start tiny8layer4+4 sequential public CBv2 stages with explicit stage-aware
verified loading, inert unused embedding/head modules and per-stage committed
state; compare logits and remapped KV/conv/SSM states before adding overlap or
transport. Stage mapping, no hidden default allocations and strict activation
ownership remain necessary. The existing source-only pipeline note is
`qwen-tp-arithmetic-and-layer-pipeline-20260913.md`.

Registered27B payload is still absent; no substitute cachedartifact is valid.
The48GiB peer remains unavailable in the last verified inventory; physical
RDMA, M3 Ultra, product scheduler and rollout criteria remain unqualified.
No remote or network configuration was changed in this checkpoint.

The permission profile changed mid-work to a managed sandbox. The first driver
attempt failed before directory creation/native execution because `/bin/ps`
was denied. Root requested and received approval for the exact four-call
driver; that command ran outside the sandbox. Subagents never ran native/GPU
work. Future commands must respect the current sandbox, not earlier full access.

## Final independent audit

Independent CPU audit completed with terminal exit 0. Receipt
`runs/qwen-gdn-input-20260913/independent-cpu-audit.json`, SHA-256
`7e5e736f060b49d71d65cbabcf4ab32415a1fa0750e5dc43634a949fa4abee1a`.
The final script is `audit-qwen-gdn-input-20260913.py`, SHA-256
`814581db7ed7ad1f846768e49a2e007e2d261d3602bee9d3f00d4a8fb8b70452`.
It verifies the four saved native exit/cleanup records, original failed receipt,
source/bundle identities, raw outputs/metrics, actual artifact, selected/fused
weights, and exact matching control logits. Optional current process enumeration
was unavailable under the managed sandbox; no fresh process absence is claimed.
First audit attempt and its optional-process-inventory failure are preserved.
No native calls were repeated. Final evidence bindings are in
`qwen-gdn-input-final-verification-20260913.json`.

Next work begins a separate arithmetic diagnostic checkpoint; this historical
build, source snapshot and original outputs remain frozen.
