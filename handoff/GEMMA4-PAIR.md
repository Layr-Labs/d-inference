# Registered Gemma 4 26B across two ranks

> Last updated: 2026-10-09 (branch `work/gemma4`, on `work/qwen-moe` at
> `c4fcd265f`, which contains the shared base `7d06b0a30`)

"Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max (128 GB). Raw logs and
reports are outside the repository in the task's evidence folder
`gemma4-20261009`; its `STATUS.md` is the live record of what has run and is
updated at every step. This document is the design, the identities and the
results that are final. Nothing here was pushed.

Runtime support and qualification only. No catalog or chip gate in the
provider was changed, and the provider still refuses to serve these models
on a pair (see "What blocks serving").

## Status

State at 17:57Z on 2026-10-09. The steps are the task's order of proof: A a
stage check on each Mac, B one staged reference as the oracle (twice,
identical), C two workers on one Mac over the local test socket, D the real
pair across the cable with one SIGTERM fault. A local-socket pass is not a
hardware pass; D is.

| Step | QAT 4-bit | 8-bit (both IDs) |
|---|---|---|
| Build, model-free checks, test bundles | **Done** on the shared base | the same binaries |
| Unit tests executed | **Not run** on the rebuilt tree | **Not run** |
| A on Mac A | **Done** at cut 12 (first smoke, binaries from the tree before the rebase) | **Not run** |
| B, the oracle on Mac A | **Done** at 31 prompt tokens, exact twice (first smoke) | **Not run** |
| C, local socket on Mac A | **Done** at 31 prompt tokens, exact against B (first smoke) | **Not run** |
| A on Mac B | **Not run** (queued) | **Not run** |
| D, across the cable | **Not run** (queued) | **Not run** |
| Fault with both stages loaded | **Not run** (queued) | **Not run** |
| Against the product engine | **Not run** | **Not run** |

Everything marked done so far is one Mac. No pair figure exists yet.

## Artifacts

Three catalog IDs, two artifacts. `gemma-4-26b` and `gemma-4-26b-8bit` are the
same thirteen files under two manifests.

| | QAT 4-bit | 8-bit | 8-bit, second ID |
|---|---|---|---|
| Catalog model ID, version | `gemma-4-26b-qat-4bit`, `2026-06-08-r1` | `gemma-4-26b`, `2026-05-25-r1` | `gemma-4-26b-8bit`, `2026-05-25-r1` |
| Runtime model ID | `registered_gemma4_26b_qat_4bit` | `registered_gemma4_26b` | `registered_gemma4_26b_8bit` |
| Manifest SHA-256 | `c1fefb1fa593fa3ca83e72a1124fb3afca10a59eed272c7ac2ac4a57f8018dfd` | `4d36eeed9afe33805bdccf9f59b4d455193ada96a56b4b4e346727a5879b0c9b` | `4e4e7df6aed1964ce70d9a3334e8114d2a18593a334c2fc3e5f2dce5ae65deed` |
| `config.json` SHA-256 | `29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa` | `1b318c90eed55cc01711dbcae4ab7604dc6f785de59b20458f9b49017c7c9cae` | the same |
| Aggregate SHA-256 | `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785` | `a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6` | the same |
| Tensor inventory SHA-256 | `da7781c57eb4864913649b547e51821398813a4b9f1c61e09bcc1fb3e7cd3c08` | `fc2b641d5de1240441b165f559fe69fcdfc074be6e5ed1a8bbc12eb5a6381207` | the same |
| Files, bytes | 10 files, 15,641,239,295 | 13 files, 27,986,040,506 | the same |
| Text tensors loaded | 1,339, 14,467,688,508 bytes | 1,339, 26,810,869,820 bytes | the same |
| Largest tensor | 369,098,752 bytes | 738,197,504 bytes | the same |
| Quantization | affine, group 64, 4-bit; 8-bit for the dense MLP's three projections and the router (120 named overrides) | affine, group 64, 8-bit | the same |

Every hash is the artifact's own: the fixtures under
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/Fixtures/registered-gemma4-*`
are byte copies of the installed `config.json` and catalog `manifest.json`.
The 358 vision tensors are not loaded. MTP is off: the QAT artifact's
speculative head is out of scope and nothing reads it. Nothing was
downloaded; both Macs already held both artifacts and the model directories
used here are copy-on-write clones of them.

## What the research archive had

The earlier research (archive `pr1229`) ran Gemma 4 as two layer stages, but
through an SDK change that was never committed to any pin: archive patches
added `Gemma4LayerStage*.swift` and `Gemma4LayerPrefillPolicy.swift` to
`MLXLLM` and made five file-private symbols of `Gemma4Text.swift` internal.
What it showed, and what it did not:

- Only the QAT 4-bit artifact, on two M4 Pro Macs (24 and 48 GB), cuts 6, 7,
  8 and 10, prompts up to 4,096 tokens. 8,192 never ran.
- Exact against a full-model reference built by the same binary. It was
  never compared with the product engine.
- It ran with the Gemma arithmetic switches unset. Product serving sets
  weighted unsort on and expert slices to `trust`.
- Its last figures at 4,096 tokens, cut 7: the pair prefilled at 454 tok/s
  and decoded at 32.0, against 370 and 47.1 for one Mac alone.
- The 8-bit artifact was only audited from metadata. The research stage
  layout would have refused its configuration.

None of that code is used here.

## Design

**A stage is the product's own layers.** `Gemma4DecoderLayer`, its
initializer and its call are public in the pinned `mlx-swift-lm`. A stage is
built in the cluster runtime from those layers at their global index with the
artifact's original configuration, so layer kind (sliding or full), head
geometry and the expert block are the product's. No SDK change was made and
none is needed. Three decisions that are private to the product's trunk are
restated in `Models/Gemma4/Model/` and are the places to look if the stage
and the product ever disagree:

1. the final layer's prefill policy (one tail row, minimum chunk 128,
   last-query prefill on);
2. the compiled logit softcap, `tanh(x / 30) * 30`;
3. the embedding scale, the square root of the hidden size.

**Geometry.** 30 layers, hidden 2,816, vocabulary 262,144, 16 query heads.
Five sliding layers (window 1,024, 8 KV heads of 256) then one full layer
(2 KV heads of 512, keys equal to values, so no `v_proj`), five times: layers
5, 11, 17, 23 and 29 are full. Each layer has a mixture-of-experts block
(128 experts, top 8, width 704) beside a dense MLP (2,112). Embeddings are
tied: both ranks own the embedding triplet, rank 0 to embed and rank 1 to
project, which is why the two stages add up to more than the text tensors.
Activations are bf16; logits are float32 after the softcap.

**Cuts.** Rank 0 holds the embedding and layers `[0, cut)`; rank 1 holds
layers `[cut, 30)`, the final norm and the logits. Because a layer keeps its
global index, any cut is structurally valid; the registered ones are 6, 8,
10, 12, 15, 18 and 24.

**Request state.** One attention row per local layer and no recurrent state.
A full layer keeps every token; a sliding layer keeps a ring of at most 1,024.
The named-state ceiling is 719,380,600 bytes at 8,320 tokens and chunk 512.

**Arithmetic contract** `gemma4_cbv2_query128_bf16_tf32_weighted_r1_v1`. A
process must have `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128`,
`DARKBLOOM_BF16_WEIGHTS=1`, `MLX_ENABLE_TF32=1`,
`MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1` and `MLX_GATHER_QMM_EXPERT_SLICES=trust`,
and must not have `MLX_METAL_GPU_ARCH`, `MLX_SDPA_BLOCKS`,
`MLX_COMPILED_DECODE`, `MLX_QUANTIZED_CONSTANT_CACHE` or any of the four
`DARKBLOOM_GEMMA4_PREFILL_*` overrides. The stage takes the product model's
own resolution of the weighted unsort, which is off for the 8-bit artifact;
that is what lets one adapter serve both.

**Modes.** The pipeline only, with the serial and the one-chunk-lookahead
prefill schedules. Phase split is not advertised: handing a sliding layer's
window from one rank to the other is not built. The compact decode framing is
model independent and could probably be advertised by adding it to
`Gemma4ResidentAdapterDefinition.supportedGenerationModes`; that was not
done and not tested.

**Where the code is.** Everything Gemma is under
`libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Gemma4/`
(metadata, model, state, loading, resources, resident). The older
`Models/Gemma/` (a retained-header profile) is untouched and unrelated.

## What changed

| Commit | Change |
|---|---|
| `909326452` | Seams in the shared runtime for a model whose product class cannot be cut: `LayerStageFrameForwarding`, `LayerStageResidentAdmission` and `LayerStageResidentStage`, `RegisteredResidentModels`, retention per layer kind |
| `2fae1d8e3` | Protocol: adapter `gemma4-layer-stage`, its three registered model and profile pairs, its arithmetic policy (8 added lines) |
| `c6e530f8d` | The Gemma 4 specification, geometry, plan, stage model, request geometry, verified loading, state budget and resident admission |
| `5bf29f69c` | The resident runtime, the reference and the service admit through the registered family instead of naming Qwen |
| `4a3db4759` | Worker, stage check, reference check, capability command, qualification request and prompt tokenizer take a registered Gemma artifact |
| `224943f24` | Tests and fixtures from the real metadata, and one check over every closed model list |
| later `wip:` commits | `handoff/gemma4-tools/` (the scripts the runs below were made with) and this document |

Only the tip was built and tested; the commits were not built one by one.

**Shared files.** Thirty files that exist on `work/qwen-moe` are modified,
307 lines added and 115 removed; the evidence folder has the exact hunks
(`shared-files-changed.diff`). The Qwen paths call the same code as before
through the two family protocols. Three things a merge must know:

- A Qwen request fingerprint is unchanged: the profile's new optional logits
  type is appended to the fingerprint only when it is set, and only Gemma
  sets it.
- The five closed lists a new model must appear in (registered
  specifications, adapter profiles, qualification models, tokenizer manifest
  pins, usage strings) are now read through `RegisteredResidentModels`, and
  `RegisteredModelListsTests` fails if a registered model is missing from
  any of them.
- Another family's branch adds a stored `layerCount` to
  `CBv2RequestGeometry`. After that merge
  `Models/Gemma4/State/Gemma4RequestGeometry.swift` must set it.

## First run on real weights (one Mac, no collective for A and B)

Mac A, QAT 4-bit, cut 12, 17:43-17:45Z, binaries built from the tree before
the rebase onto the shared base (the Gemma sources are the same; hashes in
the evidence folder under `qat4/pre-rebase-binaries/`). No memory-gate
refusal.

- **A.** Rank 0 (12 layers): 6,036,214,808 bytes loaded in 7.9 s. Rank 1
  (18 layers): 8,846,709,796 bytes in 8.0 s. Both released, a few kilobytes
  active afterwards, model object deallocated. Both ranks derive storage
  commitment `09f43f2ee0af...54c0`; the verified aggregate is the registered
  one.
- **B.** The staged reference, 31 prompt tokens, 64 outputs, twice in
  separate processes: verdict `exact` (tokens, final row, all 90 state
  digests). The text is a correct answer to the prompt. 14.88 GB active with
  both stages loaded, peak 15.16 GB.
- **C.** Two worker processes over the local test socket, the same request:
  `exact` against B, ranks agree, both exit 0, no worker left. The socket
  transport is for correctness only; its timings mean nothing for a pair.

These three are being repeated with the rebuilt binaries at 31, 4,096 and
8,192 prompt tokens before step D.

## What blocks serving

Nothing in the provider was changed. A pair cannot serve Gemma 4 today, by
design, in at least these places (paths from the repository root, lines at
`224943f24`):

| Where | What |
|---|---|
| `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPairServingTable.swift:110` | The serving table has rows for the two Qwen models only; any other runtime model is refused with `noRow`. A Gemma row needs its own startup, first-token, admission and shutdown budgets, derived from pair measurements |
| `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPlan.swift:25` | The installed plan accepts one arithmetic policy ID, the Qwen one. Gemma's capability carries `gemma4_cbv2_query128_bf16_tf32_weighted_r1_v1` |
| `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPlan.swift:68` | The worker environment the provider builds has the three Qwen variables. A Gemma worker refuses to start without the two Gemma ones |
| the same plan | Phase split and compact decode are what the Qwen pair's decode figures rest on; Gemma has the plain pipeline only |
| coordinator (another repository) | Not read and not changed here. Whatever pair approval and model eligibility say for the Qwen models has no Gemma counterpart that this work knows of |

Beyond code: a grant for a pair on mixed chips needs the items listed in
`QWEN27B-PAIR.md` under "What a distributed execution policy must state"
(identity tuple, members by rank, accepted comparator verdicts across chips,
memory per member and cut, time budgets, transport, scope). None of that
exists for Gemma.

## Resuming

The scripts are in `handoff/gemma4-tools/`; `env.sh` finds the task root from
where they are. On the Mac that owns the lanes:

1. `build-products.sh` (compile lane), then `install-binaries.sh`.
2. `abcd.sh KEY CUT` under the GPU lane: steps A, B, C on that Mac, then the
   second lane, `stage-peer.sh` and step D. `KEY` is `qat4`, `g26` or `g26x8`.
3. `widen.sh KEY CUT`: each Mac alone, and the second Mac's reference.
4. `run-tests.sh OUT` and `regress-qwen.sh` under the GPU lane.
5. `ladder1.sh KEY CUT "" SECOND_CUT` runs the comparison with the product
   (greedy, MTP off, app layout) last.

The evidence folder's `STATUS.md` says which of these have run.
