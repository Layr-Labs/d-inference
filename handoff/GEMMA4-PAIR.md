# Registered Gemma 4 26B across two ranks

> Last updated: 2026-10-09 23:50Z (branch `work/gemma4`, on `work/qwen-moe` at
> `c4fcd265f`, which contains the shared base `7d06b0a30`)

"Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max (128 GB). Raw logs and
reports are outside the repository in the task's evidence folder
`gemma4-20261009`; its `STATUS.md` is the running record. Nothing here was
pushed.

Runtime support and qualification only. No catalog or chip gate in the
provider was changed, and the provider still refuses to serve these models
on a pair (see "What blocks serving").

## Status

The steps are the task's order of proof: A a stage check on each Mac, B one
staged reference as the oracle (twice, identical), C two workers on one Mac
over the local test socket, D the real pair across the cable (rank 0 on Mac A,
rank 1 on Mac B) with one SIGTERM fault. A local-socket pass is not a hardware
pass; D is. Verdicts are judged by the owner's rule for mixed chips (decided
2026-10-09): a run passes when its tokens equal the reference (`exact` or
`tokensEqualLogitsDiffer`) or first differ at a near tie (`divergedAtNearTie`,
4 ulp); `diverged` and `incomparable` fail.

| Step | QAT 4-bit, cut 12 | QAT 4-bit, cut 18 | 8-bit (both IDs), cut 12 |
|---|---|---|---|
| Build, model-free checks | **Done** | the same binaries | the same binaries |
| A on Mac A and on Mac B | **Passed** | **Passed** | **Passed** |
| B, the oracle on Mac A (31, 4,096, 5,120, 8,192 tokens) | **Passed**, exact twice | **Passed** (no 5,120) | **Passed** |
| C, local socket on Mac A (31, 4,096) | **Passed**, exact | **Passed**, exact | **Passed**, exact |
| D, preflight and ranks agree | **Passed** | **Passed** | **Passed** |
| D, tokens against the oracle | **Failed at 31 tokens** (`diverged`); 4,096, 5,120, 8,192 pass | **Passed**, every size and mode | **Failed at 4,096 and 5,120** (`diverged`); 31 and 8,192 pass |
| D, SIGTERM fault on rank 1 | **Passed** | **Passed** | **Passed** (each ID) |
| Each Mac alone, Mac B's reference | **Done** | not run | **Done** (`gemma-4-26b`) |
| Against the product engine | not run | not run | not run |

Unit tests on the tip: worker package 60 of 60, startup checks 15 of 15,
library 126 of 127 (the one failure reads this Mac's live kernel counters and
is not Gemma code; see "Findings"). The registered Qwen 9B is unchanged on
real weights (stage receipts and an 8,192-token reference `exact` against the
earlier build).

Every `diverged` is at a small reference margin (0.05 to 0.30 logits) at a
position where Mac A's and Mac B's own references agree with each other. The
same rule fails Mac B's own reference against Mac A's at 8,192 tokens for
both artifacts, where the pair passes. Whether the pair's flips are only the
two chips' arithmetic mixed is not proven; see "Correctness across the cable".

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
| `2178b6c0c` | The shared-base Qwen identity test covers the Qwen adapters only (it failed once Gemma's adapter existed) |
| `wip:` commits | `handoff/gemma4-tools/` (the scripts the runs above were made with, the per-directory staging fix, the one-hold 5,120-token run) and this document |

The binaries used for every run were built from the sources of `88971c738`; the Swift sources at the tip differ only by the test change in `2178b6c0c`. Only the tip was built and tested; the commits were not built one by one.

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

## Stage loads (step A)

`darkbloom-cluster-stage-check`, verified load and release, no collective.
Every receipt has the model released, a few kilobytes active afterwards, and
the same storage commitment, parameter layout and verified aggregate on both
Macs and both ranks. No memory-gate refusal in any run of this session.

| Artifact | Cut | Rank | Layers | Bytes loaded | Load, Mac A | Load, Mac B | Commitment |
|---|---:|---:|---:|---:|---:|---:|---|
| QAT 4-bit | 12 | 0 | 12 | 6,036,214,808 | 7.6 s | 7.3 s | `09f43f2ee0af…` |
| QAT 4-bit | 12 | 1 | 18 | 8,846,709,796 | 8.2 s | 7.6 s | `09f43f2ee0af…` |
| QAT 4-bit | 18 | 0 | 18 | 8,846,704,164 | 8.3 s | 7.6 s | `de70d7705695…` |
| QAT 4-bit | 18 | 1 | 12 | 6,036,220,440 | 7.7 s | 7.1 s | `de70d7705695…` |
| 8-bit | 12 | 0 | 12 | 11,194,946,584 | 13.3 s | 12.2 s | `45b869427402…` |
| 8-bit | 12 | 1 | 18 | 16,400,258,084 | 14.1 s | 13.1 s | `45b869427402…` |

The second 8-bit ID loads the same bytes with the same commitment. Load times
include hashing the stage's tensors.

## The oracle (step B) and the local pair (step C)

Both stages in one process on Mac A (`darkbloom-cluster-reference`), chunk 512,
greedy, no stop IDs, prompts in the artifact's chat format with thinking off:
31 tokens (64 outputs), 4,096 (64), 5,120 (64) and 8,192 (128). Every request
run twice in separate processes is `exact` (tokens, final row and all 90
state digests), at cut 12 and cut 18 for QAT 4-bit and at cut 12 for both
8-bit IDs. The two 8-bit IDs select identical tokens. Two workers over the
local socket are `exact` against the oracle at 31 and 4,096 tokens in every
configuration. With both stages loaded the QAT process holds 13.86 GiB active
(peak 15.0 GiB at 8,192), the 8-bit one 25.7 GiB (peak 26.8 GiB).

## Correctness across the cable (step D)

`darkbloom-cluster-pair-check run`, guarded JACCL over the Thunderbolt link,
rank 0 on Mac A, rank 1 on Mac B, pipeline mode. Every run: preflight passed
(link ready on both Macs, worker and metallib hashes identical), ranks agree
on every token, both workers exit 0, no worker left, run files removed.
Serial and one-chunk-lookahead prefill give `exact` the same tokens and state
on the pair at every size tried. Margins are the oracle's top-1/top-2 gap at
the first differing token.

| Artifact | Cut | Prompt | Pair vs Mac A oracle | Rule | Mac A vs Mac B references | Pair vs Mac B reference |
|---|---:|---:|---|---|---|---|
| QAT 4-bit | 12 | 31 | `diverged` at 7, margin 0.30 (B: 0.83) | **fail** | `tokensEqualLogitsDiffer` | `diverged` at 7 |
| QAT 4-bit | 12 | 4,096 | `tokensEqualLogitsDiffer` | pass | `tokensEqualLogitsDiffer` | `tokensEqualLogitsDiffer` |
| QAT 4-bit | 12 | 5,120 | `tokensEqualLogitsDiffer` | pass | `tokensEqualLogitsDiffer` | `tokensEqualLogitsDiffer` |
| QAT 4-bit | 12 | 8,192 | `divergedAtNearTie` at 46, margin 0.0 | pass | `diverged` at 15, margin 0.17 | `diverged` at 15 |
| QAT 4-bit | 18 | 31, 4,096, 8,192 | `tokensEqualLogitsDiffer` | pass | not run at 18 | not run |
| 8-bit | 12 | 31 | `tokensEqualLogitsDiffer` | pass | `tokensEqualLogitsDiffer` | `tokensEqualLogitsDiffer` |
| 8-bit | 12 | 4,096 | `diverged` at 21, margin 0.25 (B: 0.12) | **fail** | `tokensEqualLogitsDiffer` | `diverged` at 21 |
| 8-bit | 12 | 5,120 | `diverged` at 20, margin 0.053 (B: 0.21) | **fail** | `divergedAtNearTie` at 50 | `diverged` at 20 |
| 8-bit | 12 | 8,192 | `tokensEqualLogitsDiffer` | pass | `diverged` at 15, margin 0.44 | `diverged` at 15 |

The second 8-bit ID gives the same token IDs as the first on the pair and on
the oracle, so the same verdicts. Each `diverged` row was repeated in both
prefill schedules (and the 31-token QAT one again after the fault) with the
same result: the pair is deterministic.

What the evidence says about the failures:

- On the pair, the state of layers 0-11 (rank 0, Mac A) is bit-identical to
  the oracle's; differences begin at layer 12, rank 1's first layer, on the
  other chip. The residual crosses the cable without changing what rank 0
  computed.
- Mac A's and Mac B's own references give final rows up to 0.6-0.9 logits
  apart on these requests. Every pair flip is at a margin below that (0.05 to
  0.30), and the two single-chip references themselves disagree at 8,192
  tokens (margins 0.17 and 0.44), where the pair agrees with Mac A.
- But at every pair failure the two single-chip references agree with each
  other, and the pair report carries no per-step logits, so the pair's own
  margin at the flip is unknown. A computation split across the two chips is a
  third arithmetic, not either chip's; that it lands on the other token at
  these margins is plausible, not shown.
- At cut 18 (rank 1 holds 12 layers on Mac B instead of 18) every request
  passes.

A decisive check would record per-step top logits on the pair (the reference
already does) or run a mixed reference: Mac A's rank-0 residual fed to Mac B's
rank-1 stage in one process. Neither tool exists.

## Speed

Medians of four requests in one session per cell, as first token (s) /
prefill (tok/s) / decode (tok/s). Driver clock: from the start command to the
token events. Pair rows are rank 0 on Mac A. "Alone" is the staged service on
one Mac (both stages in one process) driven the same way. The 5,120-token row
was measured with the pair and each Mac alone inside one hold of the lanes; the
4,096 and 8,192 alone figures are from a later hold than the pair's. Every
run held the GPU lane on Mac A and the Mac B lane; the two compile lanes were
not taken, so another worker's compile may have shared Mac A during a run.
Repeats within a cell agree to a few percent.

| Artifact | Cut | Prompt | Pair serial | Pair lookahead | Mac A alone | Mac B alone | Same hold |
|---|---:|---:|---|---|---|---|---|
| QAT 4-bit | 12 | 4,096 | 1.65 / 2,488 / 59.9 | 1.07 / 3,838 / 63.5 | 2.32 / 1,764 / 57.3 | 1.06 / 3,867 / 82.5 | no |
| QAT 4-bit | 12 | 5,120 | 2.05 / 2,499 / 64.1 | 1.31 / 3,899 / 63.3 | 2.89 / 1,774 / 64.5 | 1.32 / 3,872 / 82.7 | yes |
| QAT 4-bit | 12 | 8,192 | 3.40 / 2,411 / 60.4 | 2.14 / 3,822 / 61.0 | 4.85 / 1,688 / 56.9 | 2.35 / 3,497 / 78.7 | no |
| QAT 4-bit | 18 | 4,096 | 1.87 / 2,190 / 63.2 | 1.48 / 2,769 / 62.2 | — | — | no |
| QAT 4-bit | 18 | 8,192 | 3.92 / 2,087 / 60.5 | 3.06 / 2,676 / 60.4 | — | — | no |
| 8-bit | 12 | 4,096 | 1.75 / 2,347 / 55.5 | 1.10 / 3,738 / 55.3 | 2.40 / 1,708 / 56.9 | 1.22 / 3,360 / 67.9 | no |
| 8-bit | 12 | 5,120 | 2.20 / 2,329 / 55.5 | 1.37 / 3,730 / 55.4 | 3.02 / 1,698 / 57.6 | 1.61 / 3,177 / 65.8 | yes |
| 8-bit | 12 | 8,192 | 3.64 / 2,249 / 53.7 | 2.20 / 3,725 / 52.9 | 4.98 / 1,645 / 56.9 | 2.65 / 3,099 / 64.7 | no |
| 8-bit, 2nd ID | 12 | 4,096 | 1.75 / 2,337 / 55.8 | 1.11 / 3,704 / 54.4 | — | — | no |
| 8-bit, 2nd ID | 12 | 8,192 | 3.65 / 2,244 / 52.8 | 2.22 / 3,683 / 53.6 | — | — | no |

- With lookahead the pair prefills as fast as Mac B alone (QAT 4-bit) or a
  little faster (8-bit, 3,725-3,738 against 3,099-3,360 tok/s), and 2.2 times
  as fast as Mac A alone. Serial prefill is about 1.4 times Mac A alone and
  slower than Mac B alone.
- Decode on the pair is 53-64 tok/s, close to Mac A alone (57-65) and below
  Mac B alone (65-83): every token crosses the cable twice and waits for both
  stages. Only the plain pipeline is admitted for Gemma (no compact decode, no
  phase split).
- Cut 18 puts more layers on the slower chip: lookahead prefill falls to about
  2,700 tok/s. Cut 12 is the better of the two.
- 31-token requests (warm): first token 0.062-0.072 s, decode 74-78 tok/s
  (QAT) and 56-62 (8-bit) on the pair.

## Fault with both stages loaded

The 8,192-token request decoding, rank 1's worker on Mac B sent SIGTERM 0.3 s
after the first committed token. Four runs (QAT cut 12, QAT cut 18, 8-bit,
8-bit second ID), the same outcome each time: rank 1 exits 255, rank 0 reports
the failed request after 21-23 committed tokens and exits 1 by itself 10-11 s
later (its progress limit), the driver sends no signal, no worker is left on
either Mac, and a request started afterwards completes with the same tokens
as before the fault.

| Run | Wired, Mac A before / after | Wired, Mac B before / after |
|---|---|---|
| QAT 4-bit, cut 12 | 10.81 / 10.75 GB | 5.28 / 7.18 GB (5.51 GB about a minute later) |
| QAT 4-bit, cut 18 | 10.23 / 10.21 GB | 5.45 / 5.35 GB |
| 8-bit, cut 12 | 9.51 / 9.44 GB | 5.32 / 5.10 GB |
| 8-bit second ID, cut 12 | 9.83 / 9.73 GB | 5.29 / 5.08 GB |

"After" is read 5 s after the driver ends. The one high Mac B reading
returned to its level within a minute; nothing stayed allocated.

## Findings

- **`tools/copy-uncached.sh` truncates a tree with subdirectories and still
  prints VERIFIED.** The `ssh` that makes a subdirectory reads the rest of the
  file list from the loop's standard input. The first staging put 8 of the 16
  binary files on Mac B (no `mlx.metallib`, no resource bundles). The Gemma
  scripts now copy one directory at a time through a directory of links and
  check the count (`31e370c7f`); the shared tool was not changed. Model
  directories are flat and unaffected; any other binary staging with bundles
  is.
- The scripts resolved their own directory through the scratch link, so the
  first staging copied the scratch directory instead of the scripts (small
  files only, no weights; removed from Mac B). Fixed in the same commit.
- A shared-base test (`ResidentAdmissionA3BTests`) compared every adapter's
  model pairs with the Qwen rows and failed once Gemma's adapter existed.
  Scoped to the Qwen adapters (`2178b6c0c`); `RegisteredModelListsTests`
  covers every family.
- `StageLoadRealSamplerTests` fails on Mac A after the reboot: it reads the
  kernel's file-cache minimum and found it 100 % off the formula (the scan did
  not run during the test). Host state, not Gemma code; not changed.
- The Gemma adapter profile caps a prompt at 8,192 tokens. The owner wants 5k,
  10k, 20k and 30k later; no limit was changed here. 5,120 fits and was run.
- No permission step was met: every run, including the first runs of these
  binaries on both Macs after the reboot, completed unattended, and nothing
  waited on a prompt, firewall or keychain request.

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
where they are (through a link too). On the Mac that owns the lanes:

1. `build-products.sh` (compile lane), then `install-binaries.sh`. Remove and
   rebuild only if the sources change; the binaries in the task's
   `bin/gemma4` on both Macs are the ones every figure above used (tree digest
   `9a4b8f0a…fa4b`).
2. `abcd.sh KEY CUT` under the GPU lane: steps A, B, C on that Mac, then the
   second lane, `stage-peer.sh` and step D. `KEY` is `qat4`, `g26` or `g26x8`.
   Finished runs are kept, not repeated; `SKIP_ABC=yes` runs only D.
3. `widen.sh KEY CUT`: each Mac alone and the second Mac's reference.
4. `same-hold.sh KEY CUT NAME TOKENS OUTPUTS`: one prompt size for the pair and
   each Mac alone in one hold (within the 8,192-token cap).
5. `run-tests.sh OUT` and `regress-qwen.sh` under the GPU lane.
6. `ladder1.sh KEY CUT "" SECOND_CUT` runs the comparison with the product
   (greedy, MTP off, app layout) last.

## Not done

- The comparison with the product engine (`darkbloom start --local`).
- The 8-bit artifact at a second cut, and Mac B's reference and each Mac
  alone at cut 18.
- The pair in the other order (rank 0 on Mac B). By the speed ratio it would
  want a cut above 15 with lookahead; not planned.
- Prompts above 8,192 tokens: the profile's cap.
- A per-step logit record on the pair, which would settle whether the
  `diverged` runs at cut 12 are arithmetic or a defect.
- Compact decode and phase split for Gemma (see "Design").
- The changes on this branch have not been independently reviewed.
