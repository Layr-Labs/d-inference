# Whole-layer extensions: Qwen3.5 35B MoE and Gemma4 26B

Source-only assessment, 2026-09-14. Qwen35B shares more of the existing compute and
state path; Gemma needs a distinct execution/state adapter. Neither is admitted by today's
dense stage gates. Keep those gates, existing wire versions and registered 9B
qualification profiles unchanged while developing separate family adapters.

## Retained identities, not a new model qualification

The retained catalog and configs resolve the otherwise ambiguous Gemma name to
two different artifacts. The JSON companions pin exact source bytes and metadata;
no weights, new safetensor headers, network, compiler or model execution were used.
The retained layouts explicitly do **not** attest a full payload hash verification.

| Retained model | Exact text geometry | Stored quantization | Declared artifact aggregate prefix |
| --- | --- | --- | --- |
| `qwen3.5-35b-a3b` | 40 layers; H=2048; 30 GDN + 10 full attention; 256 experts, top 8; shared width 512 | affine W4/G64, BF16 metadata | `95811153b3bb` |
| `gemma-4-26b-qat-4bit` | 30 layers; H=2816; 25 sliding + 5 full attention; 128 experts, top 8 | affine W4/G64 default; 120 W8/G64 dense-MLP/router overrides | `2468a0cb3049` |
| `gemma-4-26b` | Same retained text geometry as QAT variant | affine W8/G64 | `a4722b6020ad` |

Both Gemma configs specify tied embeddings, sliding window 1024, 8 sliding KV heads
of width 256, 2 full-attention KV heads of width 512, full-attention K=V,
zero KV-shared tail layers, zero per-layer-input
width and text-compatible `use_bidirectional_attention="vision"`. Their semantics
are not interchangeable with Qwen GDN. Vision/video and MTP/assistant execution
remain separate capabilities. The historical catalog is not a current provider
eligibility check.

## Exact barriers in the current stage stack

| Surface | Barrier and reusable part |
| --- | --- |
| `QwenLayerStagePlan.init` / `QwenStageMetadata.validate` | Only `qwen3_5`/`qwen3_5_text`; rejects positive expert fields and tied embeddings. Mandatory dense `intermediate_size` and dense module inventory do not describe the Qwen MoE config, which also has `router_aux_loss_coef`. Gemma has different layer types, metadata and assets. Preserve the exact raw config; use family-specific admission, not removed keys or a permissive regex. |
| `moduleInventory`, `parameter`, `localModule`, `policy` | Dense paths omit Qwen router/shared/switch modules and Gemma router/direct scales, experts, extra norms and layer scalar. Existing sorted ownership/quantization-remap machinery is useful only after a family supplies its complete canonical inventory. Quantization aliases and nonquantizable parameters need explicit schemas. |
| `prepareVerifiedQwenLayerSource` / `prepareQwenLayerStageModel` | Concrete dense-MLP assertions reject `Qwen35SparseMoeBlock`; each canonical tensor must have one stored part. MoE expert gate/up composition has two. Actual shape/dtype/layout verification and compact owned-copy checks should remain mandatory. |
| `loadVerifiedQwenLayerStageBaseline` / `QwenLayerStageSession` / `CBv2RequestGeometry` | Baseline and session hardcode family Qwen, feed-forward kind dense, concrete `Qwen3NextMLP`, and recurrent Qwen forwarding protocols. Geometry accepts full attention without shared KV, plus GDN. Gemma cannot enter through these recurrent-only casts. |
| `CBv2OwnedRequestState.validateState` / `CBv2OwnedStateSnapshot.capture` | Assert retained KV count equals the complete token frontier and shape `[1,KV,T,D]`; that is wrong for bounded sliding storage after eviction. Retain the ownership, eval-root, frontier, retirement and global-index discipline; derive retention/state shapes from the admitted family instead. |
| `LocalCorrectnessStorage` | Existing limits are artifact 8 GiB, canonical source 6 GiB, rank 4 GiB and host tensor 512 MiB. All three declared artifacts exceed 8 GiB; retained text namespace payloads exceed 6 GiB. Gemma W8's embedding weight alone is 738,197,504 bytes, above 512 MiB. The artifact/host limits already give independent refusals; a canonical inventory and loading-peak budget still need derivation. No limit is changed here. |

Sources are the named files under `experiments/cluster/inference/Sources/ClusterInference/`.
The descriptors and scopes are pinned in [source-pins.json](source-pins.json).
The retained config/layout facts are in [metadata-summary.json](metadata-summary.json);
raw text namespace totals are not a derived canonical stage inventory.

## Qwen MoE: preserve whole-layer arithmetic

`ModelLoading.constructQwenModel` already selects `Qwen35MoEModel`, a subclass of
`Qwen35Model`. `Qwen35.swift` uses the same decoder attention/GDN and CBv2 trunk
for dense and sparse MLPs. For this exact config, keep each entire router, all
256 experts, the shared expert and sigmoid shared gate on its layer's owner.
No expert-ID remapping, routed reduction across stages, or new collective belongs
inside that layer. Attention/GDN state components remain KV/offset and conv/SSM;
the FFN has no new request cache in this source.

The interval-4 constructor selects attention from the local index. Structural
cuts 4, 8, ..., 36 preserve that phase for 40 layers, subject to
new family admission and real storage proofs. Preserve top-8 ordering, precise
softmax, top-k normalization (missing config value defaults true), shared-branch
order and BF16 reduction behavior. `Qwen35A3BOptimization.swift` also chooses a
construction-profile-dependent router for the exact H=2048/E=256/top-8 geometry and
small row counts. `SwitchLayers.swift` has a production SwiGLU reduction selector.
The matched baseline and stages must bind these dispatch policies; the prior tiny
H=128/E=16 MoE proof did not exercise them.

The retained artifact stores split `switch_mlp.gate_proj`/`up_proj` packed triplets.
The ordinary Qwen sanitizer can fuse or keep them split according to resolved
policy; its aliases span raw/wrapper/bare names. `PreparedQwenCheckpoint` and
`QwenCheckpointTensor` already represent a matching rank-three gate/up pair and
compose along output axis 1. Reuse that explicit composition knowledge for whole
tensor loading, preserving the expert axis and exact metadata, rather than
feeding names through the dense one-part source record. The current composition
reader includes evaluation/synchronization and can hold source pieces alongside
the fused destination: its byte accounting is not a full loading-peak bound.
Heterogeneous split policies must retain their topology or reject explicitly.

## Gemma: endpoint and global-layer semantics matter

`Gemma4Text.swift` has a scaled input embedding (`sqrt(H)`), seven layer norms on
each retained MoE layer, a dense branch and a sparse GeGLU branch with separate
post-norms, a router RMS scale plus per-expert scale, and a final layer scalar.
The router chooses the top 8 logits, then softmaxes the selected logits and applies
per-expert scaling. Qwen's gate/MLP layout and norm recipe cannot stand in for it.

The last endpoint uses `embedTokens.asLinear` when embeddings are tied, followed
by a logit softcap of 30. Replacing stage 1's embedding with the current dtype-only
placeholder would corrupt the output head. Both endpoints need the real tied
asset in separate processes. Its retained triplets total 415,236,096 bytes for QAT
or 784,334,848 for W8. A Gemma ownership ledger must explicitly distinguish unique
source bytes from replicated physical stage bytes; today's exclusive-owner
`sum(stage bytes)==source bytes` invariant must remain intact for the old Qwen
adapter. Do not silently untie the model or manufacture an unrelated head.

The exact configs have no cross-layer KV borrowing or PLE. A future Gemma family
with either feature needs dependency-aware cuts: KV source and borrower must stay
together or use an explicitly extended boundary; PLE depends on the original
embedding/projection and cannot be regenerated from an internal residual. Slice
the explicit global layer-type list and preserve global identities; do not impose
Qwen's modulo-4 rule on Gemma.

Two compact-construction hazards require an explicit source-semantic seam:

- Scheduled `forwardTrunk` narrows the **last local** layer and may select its
  last-query path. Internal stages must retain every hidden row. The existing
  pre-norm MTP forward avoids scheduled narrowing but also skips scheduled expert
  behavior; it is not automatically the same baseline execution path.
- `gemma4SupportsProductionExpertTopology` requires `numHiddenLayers==30`.
  Compacting a stage disables that predicate, and interval-18 async submissions
  are counted locally. Preserve admitted full-source dispatch identity and global
  final-layer/submission roles explicitly; do not falsify the compact layer count
  or relax the production optimization gate. Alternatively, qualify a separately
  declared common baseline/stage policy before enabling production policies.

Keep the W4 versus W8 artifact distinction, root-to-text quantization propagation,
all 120 overrides, full-attention K=V projection omission, different rotary
rules and attention scale 1.0. Converted text namespaces, vision/audio exclusions,
raw packed-expert splitting and tied-head presence need a Gemma sanitizer adapter.
The existing Gemma FFN partition loader is useful prior work, not a verified
whole-layer/CBv2 stage loader.

## Small shared adapter seam

Introduce a versioned **admitted family descriptor**, consumed by the existing
ownership/orchestration shell. It supplies five explicit contracts:

1. Exact original config, family/version, ordered global layers and legal cuts.
2. Canonical source-to-local assets, one/multiple source-part composition, resolved
   quantization and explicitly replicated endpoint assets with byte accounting.
3. Compact constructor plus full-source semantic roles/dispatch identity.
4. Model-derived state kinds, native dtypes, retained-window/frontier rules and
   local/global index map.
5. Token-entry, residual-entry and final-logit behavior with all required eval
   roots, preserving the current catch/retire and CPU-only evidence boundary.

Start with a Qwen-MoE descriptor while leaving the dense descriptor and identities
unchanged. Implement Gemma separately against the same ownership shell. Shared
request schedules, strict JSON scanning, token/source/plan hashes, B1 residual
transfer, ACK phases, bounded queues and parent cleanup can remain. Their existing
Qwen-typed admission/expectation adapters still need deliberate family bindings;
new support does not follow from the low-level packet fitting. Keep existing
v1/v2/v3/v4 bytes/caps and the registered 9B 8K profile unchanged. New cross-layer
state in a boundary would require an explicit new protocol contract.

First gates: public tiny complete saved-model load and full-width stage parity;
all canonical names/shapes/dtypes and composition bytes; tied-asset replication;
global/local state coverage through sliding wrap where applicable; full native
logit comparisons with exact input/chunk/policy identities; routing/tie cases;
failure/cancel/release after partial commits; then separately budgeted real
artifacts and physical-pair checks. No bypass of provider/artifact/resource gates
is part of this proposal. Compute costs and useful cut rankings remain unknown;
neither equal-layer cost nor MoE throughput is inferred from the dense 16-layer
timings or these metadata sizes.

## Source anchors

These line numbers refer to the exact file hashes in `source-pins.json`, not a
claim that the working tree is clean or that a build was reproduced.

| Pinned source | Relevant symbols/locations |
| --- | --- |
| `PreparedQwenLayerSource.swift` | `prepareVerifiedQwenLayerSource`, line 24; one-part guard, line 62 |
| `PreparedQwenCheckpoint.swift`, `QwenCheckpointTensor.swift` | sanitizer/policy preparation; explicit expert-pair composition, line 74 of the latter |
| `Qwen35.swift` | `Qwen35SparseMoeBlock`, line 1374; `Qwen35DecoderLayer`, line 1461 |
| `Qwen35MoE.swift` | `Qwen35MoEModel.sanitize`, line 251 |
| `Gemma4Text.swift` | production-topology predicate, line 94; `forwardTrunk`, line 1612; `applyLMHead`, line 1983; `sanitize`, line 2065 |
| `QwenLayerStageSession.swift`, `CBv2RequestGeometry.swift`, `CBv2OwnedRequestState.swift` | current dense Qwen entry/state restrictions and retained-frontier checks |
