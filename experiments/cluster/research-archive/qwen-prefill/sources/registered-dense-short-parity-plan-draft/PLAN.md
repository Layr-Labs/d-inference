# Minimal registered dense short-parity bridge

Status: Proposed, 2026-09-14. Source/design only; no implementation, compiler,
native, SSH, new model payload or candidate output access by this author.
Source dependencies are pinned in `source-pins.json`. Root reports the new 27B
constructor passed, but constructor metadata does not qualify materialization or
forward arithmetic. The existing selected-stage loading probe remains unchanged.

## Concrete next path

Add one isolated `qwen-dense-short-parity-check` entry for the exact registered
9B/27B profiles and default halves only. Fix the request at **3 prompt IDs,
chunk 2, output count 2, one supplied teacher ID**, batch one, seed 7, one run,
zero warmups. This gives intermediate prefill, final prefill and decode at
frontiers **2, 3, 4**, with two full-vocabulary logit rows. Retain exact bounded
raw prompt/teacher bytes and caller SHA256 pins; do not synthesize or sample
history. No user geometry, cut, tracing, transport, precision, resource-reserve
or throughput options are added. Proposed native timeout remains 1...300 seconds.

Reuse `recordQwenLayerStageBaseline` and
`compareQwenLayerStageRecordedRequest` without changing their numerical loops:

```text
exact metadata/raw-input admission + current resource screen
  → one VerifiedCheckpoint full checksum pass
  → private full-reference load + existing baseline recorder
  → close request, release full model, synchronize, check errors, clear cache
  → publish completed CPU-only baseline checkpoint
  → private two-stage load + existing sequential pair comparator
  → close both requests, release both models, synchronize and clear cache
  → final file/resource/error checks → bounded success record
```

Only CPU evidence crosses the full-model/stage boundary. Both stage models remain
resident together during the existing comparator. Loading each stage and saving
all its residuals for later replay would require a new coordinator and boundary
retention contract; it is outside this minimal increment. Do not claim the
one-stage load memory floor covers this pair.

## Existing seams and required changes

| Concern | Existing source / smallest change |
|---|---|
| Pure exact admission | Reuse `QwenDenseConstructorAdmission`, raw profile pins and default Plan; add a separate immutable short request that builds actual `QwenLayerStageRequestSpec`/`QwenLayerStageRecordedRequest`. Do not clone or widen ordinary Options. |
| Full baseline loading | `loadVerifiedQwenLayerStageBaseline` calls the legacy `loadVerifiedQwenDiagnostic`, whose source/host caps reject 27B. Extract its payload/update/freeze/receipt tail exactly once, preserving the old wrapper and all checks. Add a separately admitted registered `.fullReference` caller using the existing verified checkpoint owner. |
| Full LoadedModel assembly | Reuse the tail of `VerifiedQwenLayerStageBaseline` after a supplied verified diagnostic receipt. Its real embedding probe and scale/KV dtype checks still execute; resource admission must precede this first arithmetic too. |
| Selected stages | `materializeQwenDenseSelectedStage` intentionally retires before returning CPU records. Factor only its private owner-local loading setup so the load-only entry still retires immediately, while a new owner retains both stages until the existing comparator returns. No public Loaded/model-returning or arbitrary continuation API. |
| Pair admission | Before either stage payload, bind both inventories and a `.sequentialPair` weight ledger. Keep selected stage gates; add the pair-wide pending-allocation and forward reserve. Stage 0's resident active/cache bytes remain present in stage 1's live sample. |
| Math/recording | Keep CBv2 sessions, `QwenSequentialStagePair`, per-frame state comparison, owned boundary copy, full native logit-byte comparison and FP32 diagnostic encoding unchanged. No provider/model operator edits. |
| Publication | A new outer namespace embeds existing baseline/comparison DTOs and resource evidence. Baseline is complete only after full-model release. Later failure preserves that checkpoint and emits no final success. Exact serialized bytes are bounded before writing. |

The new full caller rebuilds `.fullReference` from actual full-constructor
observations. It must not feed the existing pair-bound read plan into a full-role
validator or relabel a selected-stage permission as full. Constructing another
full metadata model may reuse the already verified descriptor owner without a
second file hash; it must reproduce the exact profile/Plan/inventory before reads.
The old 6 GiB source/512 MiB host/8 GiB artifact limits remain untouched.

## Forward resource admission

Reuse direct `QwenDenseStageLoadResources` observations and
`QwenDenseStageLoadPolicy.requireInitial`: actual free at least **6 GiB**, pressure
0...2, absolute swap zero, checked page accounting and sample freshness. Reclaimable
bytes and recommended working set stay diagnostic. No caller reserve or earlier
constructor success is a runtime permit; sample again after hashing and before
materialization, before request-state construction/embedding arithmetic, at each
existing checked forward boundary and after cleanup.

A new pure short ledger must be distinct from `QwenDenseStorageRequirement`'s
explicit **8192/512/1** fields. Reuse that requirement for its exact profile/role/
weight and fusion identities only, without relabelling its token profile or final
state. For this request, call the existing checked
`QwenLongPrefillTensorBudget.estimate(geometry:maximumTokens:5,chunkSize:2)` and
retain its 512 MiB named-tensor ceiling. The source arithmetic vectors are
160,563,232 B for 9B and 474,562,624 B for 27B; these are named tensors, not an
allocator or complete process bound. Actual allocator bounds must be derived for
the individual live arrays, not by rounding a single aggregate.

The private parity gate needs the current leg's complete remaining weights `R`,
largest host copy `H`, and an additional forward envelope `Q`. Retain the current
load formula and add the new envelope:

```text
actual free >= max(6 GiB, R + 2H + Q + 4 GiB)
allocator limit >= observed active + cache + R + H + Q + 2 GiB
```

`R` covers the whole full-reference leg or both stages, including conservative
inert allowances. At forward time `R=H=0`; all resident bytes are still observed.
`Q` must include allocator-bounded recurrent/KV generations, state snapshot and
boundary copies, complete logit CPU/FP32 diagnostic copies, and first-use GDN
fusion replacement/cache overlap. Build fused-buffer shapes from the four actual
quantized projection triplets in each recurrent layer and require their logical
sum to match the existing `fusionReplacementBytes`. Do not count the entire
current parameter set a second time. For 27B the source logical fusion allowance
is 2,278,195,200 B across all 48 GDN banks; it is neither rounded nor a proven
permanent second copy. The actual Qwen constructor evaluates concatenated fusion
weights/scales/biases on first forward, so load-only gating cannot cover that step.

The 4/2 GiB constants remain operational headroom for unnamed native scratch and
framework overhead, not a measured peak bound. Retain max-buffer checks and
checked sums. No frame or internal fusion may be assumed allocation-free; the
parent still samples, owns deadline/fencing and reaps all processes. A positive
CPU predicate is not a live permission, and a refusal never lowers the threshold.
Do not advertise that the full/pair scope fits a 24 GB machine. The new gate and
its failure paths need qualification on the eventual source-matched hardware.

## 27B assumptions to keep explicit

- The closed registered 27B is still the existing dense `qwen3_5`/Qwen35 path:
  64 layers, hidden 5120, attention query/KV heads 24/4, GDN value/key heads 48/16,
  dimensions 128/128 and attention interval 4. The 32/32 cut preserves phase.
  Full/compact CBv2 geometry is model-derived; no 9B-only 32-layer/16-half or
  72-state assumption belongs in the new owner or oracle.
- `Qwen35DecoderLayer.cbv2Forward` and its full/embedding wrappers share the same
  attention, GDN and dense `Qwen3NextMLP` operators. `GatedDelta.swift` uses Hv/Hk
  in both kernel mapping and operations fallback, so 48/16 is represented in
  source. This is source compatibility, not hardware arithmetic qualification.
- Preserve original `output_gate_type=swish` bytes and the already admitted
  SiLU declaration semantics; no gate substitution. Keep MTP disabled, untied
  embedding/head ownership, native BF16 weights/activations, FP32 SSM and the
  frozen arithmetic environment. Do not enable exact-target/MTP or FP32 variants.
- Expected complete state coverage is 72 components for 9B and 144 for 27B at
  each of three frontiers, split 36/36 and 72/72. Derive the exact global key,
  shape, dtype and byte inventory from the Plan and geometry; counts alone fail.
- Provider allowlists, M3/operator qualification and other workloads remain
  separate. A full-versus-stage match shares model operators; it does not supply
  an independent upstream/reference implementation or broad model correctness.

## Review and qualification before any new model run

Pure fixtures should exercise exact registered profiles, malformed raw pins,
fixed history counts/ranges, default Plan binding, role/leg replay, omitted forward
reserve, coherently swapped peer ownership and one-byte resource boundaries.
Test full/pair resource refusal before a real private callback can read a payload
or allocate request state; pure scalar counter tests cannot establish that order.
Cover throws after a partial load, first fusion/forward, snapshot, comparator,
publication and cleanup, retaining primary/native error precedence and no final
success. Existing legacy tiny/short regression and old adapter output must remain
unchanged after the loading-tail extraction.

Freeze a new small oracle before candidate access: three frames/two full rows,
exact request/Plan/source/storage joins, all 72/144 state entries per frontier and
full native row reconstruction from finite reported values. Reuse the established
exact numeric checks; never widen tolerance to obtain parity. Root first qualifies
the same closed path on 9B, then selected 27B load controls and the full/pair memory
gates, then the 27B short request if live guards admit it. No throughput clock,
physical transfer, long prefill, resident reuse or public launcher is added here.
