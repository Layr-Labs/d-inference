# Registered MiMo V2.6 Flash across two Macs

> Last updated: 2026-10-09 22:50Z (branch `work/mimo`, base `e15f5b891`). Work in progress: the pair has run at cuts 34 and 30, short and 4,096-token prompts, repeated, and with one rank ended by SIGTERM. The pair's short-request difference from the single-Mac reference (token 28) is **mixed-chip numerics at an exact tie**: both ranks on one Mac reproduce the reference bit for bit. The 4,096 difference (token 50) is not yet classified.

"Mac A" is the M3 Ultra (256 GiB), "Mac B" the M5 Max (128 GiB). Raw logs,
receipts and gate records are outside the repository in the task's evidence
folder `mimo-20261009`. Nothing here was pushed.

MiMo is the one catalog model that needs the pair: 172.9 GB of weights against
a 256 GiB Mac whose single-Mac load needs about 183 GiB usable. As a two-stage
layer pipeline neither Mac holds more than about 103 GiB of it.

## Status

| Step | State | Evidence (folder `mimo-20261009`) |
|---|---|---|
| Admission, ceilings and capability from the real metadata | the eight model-free check runners pass on `846d461c8`; runtime unit tests **128 of 128 passed** and startup checks **31 cases passed** on builds 6 and 7 | `unit/pure-4/`, `unit/build6.*`, `unit/build7.*` |
| Stage load and release, rank 1 on Mac B | **passed at cut 40** (26.87 GiB) after four loads the growth guard stopped; **refused at cut 28** by the committed rule (72.27 GiB needed, 61.62 free); **passed at cut 34** twice (46.56 GiB, builds 6 and 7) | `stage-load/B-*` |
| Stage load and release, rank 0 on Mac A | **passed at cut 34** twice (109.21 GiB, builds 6 and 7) | `stage-load/A-rank0-cut34-*` |
| Single-Mac reference | **ran** at cut 34 on Mac A (both stages in one process, 167.3 GB active), short and 4,096. Short: both ranks on Mac A over the local test socket are **exact** to it (35 of 35 rows bit for bit); across the cable the verdict is **`divergedAtNearTie`**: the reference's row at token 28 is an exact tie (264 = 279 = 23.625) and the M5 Max's rank 1 breaks it the other way. 4,096: `diverged` at token 50, not yet recorded with step evidence | `reference/` |
| Pair across the cable | **passed** at cut 34 (short twice, same 37 tokens; 4,096 once) and at cut 30 (short, the same 37 tokens); one 4,096 attempt failed before ready because Mac B's link port had lost its address (below) | `pair/pair-cut34-short-{1,2}.*`, `pair-cut34-4096-2.*`, `pair-cut30-short-1.*`, `pair-cut34-4096-1.*` |
| One rank ended mid-request | **passed with a finding**: rank 0 SIGTERM mid-decode (29 tokens in); rank 1 exited by itself only at the 180 s JACCL progress timeout; nothing left on either Mac, wired memory back | `pair/pair-cut34-fault-sigterm-rank0-1.*` |
| Stage ended with SIGTERM mid-decode | **passed** on both Macs at cut 34: wired memory back to its level within 1 s | `stage-load/*-cut34-sigterm-b7.sigterm.txt` |
| Worker package XCTest suites | **passed**: built (`unit/worker-xctest-build-7.log`), 41 XCTest tests, 0 failures | `unit/worker-xctest-7.txt` |

`STATUS.md` in the evidence folder is the live record: every attempt, the
binaries on each Mac, what is in flight and the next command.

## How the product runs MiMo, and what the pair runs

The product serves `mimo-v2.6-flash-mopd` through the same continuous-batching
engine as the Qwen models, but through a path of its own: the provider's
`MiMoV26ServingLoad` drives the SDK's native factory and strict loader
(`MiMoV26ModelFactory`, `MiMoV26SerialLoadSession`, `MiMoV26FilesystemWeights`
in `MLXVLM`), which builds a `MiMoV26LoadedModel`. Its text target is
`MiMoV26TextModel` (`MLXLLM`: `MiMoV26TextBackbone`, `MiMoV26DecoderLayer`,
`MiMoV26Attention`, `MiMoV26MoE`), and the engine steps it through
`MiMoV26CBv2Adapter` with a native paged KV pool, the three embedded MTP heads
as a speculative assistant, an audio sidecar and a vision tower.

The pair runs the same `MiMoV26TextModel` class, one compact instance per
stage, through the class's own public forward:

- stage 0 is given token IDs and returns the residual the class captures after
  the stage's last layer (`captureLayers`), before any final norm;
- stage 1 is given that residual as input embeddings and returns logits.

That is the product's ordinary-cache text path, not the path its engine serves
through: state is the class's own `KVCacheSimple` and `RotatingKVCache`, not the
paged pool; there is no MTP, no vision, no audio. The weights, the layer
arithmetic and the kernels the class selects by default are the product's. The
adapter exposes neither a residual egress nor an ingress and needs the native
construction scope, so putting a stage on the engine's own adapter is a change
in `libs/mlx-swift-lm` and was not made. Speed and near-tie tokens against the
product engine are therefore measured, not assumed.

## Architecture facts the adapter rests on

Read from the artifact's `config.json` and shard headers, and pinned in
`MiMoRegisteredSpecification`:

- 48 pre-norm residual layers, hidden 4,096, vocabulary 152,576, `bfloat16`.
- Layer 0 has a dense MLP; layers 1 to 47 route over 256 experts, 8 per token.
- Nine layers attend over the whole history (0, 5, 11, 17, 23, 29, 35, 41,
  47; four key-value heads); the other 39 keep a window of 128 positions
  (eight key-value heads, a learned sink bias). Keys are 192 wide, values 128.
- A layer is `x + attention(norm(x))`, then `+ mlp(norm(.))`. Its attention
  state is its own and positions come from its own cache offset. So any layer
  boundary is a cut, and only the residual `[1, tokens, 4096]` in `bfloat16`
  crosses it: 8,192 bytes per token, 4 MiB for a 512-token chunk.
- Request state is keys and values only: 23,040 bytes per token over the nine
  full-attention layers plus a constant 24.4 MiB for the windows; about
  207 MiB for the whole model at 8,320 tokens. There is no recurrent state.
- The MTP heads read the output of the final norm (they would live with
  stage 1); vision and audio feed the embedding ingress (stage 0). None of the
  three is part of the pair: text, greedy, MTP off.

One numeric note. For rows of one to seven tokens the class fuses each layer's
finish with the next layer's input norm in one kernel. At the cut, stage 0
runs that kernel against a placeholder norm (its residual output does not
depend on the norm) and stage 1 computes the norm itself with the stock
operation. A unit test builds a tiny random four-layer MiMo
with the product's class and compares the whole model with its two stages at
every cut, prefill and decode, in bfloat16: it passed. There is no single-Mac
comparison on the real weights yet.

## Artifact

| Field | Value |
|---|---|
| Runtime model ID | `registered_mimo_v26_flash_mopd` |
| Catalog model ID, version | `mimo-v2.6-flash-mopd`, `2026-09-28-r1` |
| Manifest SHA-256 (the catalog's manifest record, 8,624 bytes) | `de1bd701115a9ee7e4a99ac85307b31285c63a0b0b1c22ef0c69e9b4ac10f346` |
| `config.json` SHA-256 | `35b6e3d4543b65e6fa9d6174e2260d9ac1d3ea1e5acb9955d9fe9f2b815d13d4` |
| Aggregate SHA-256 | `2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034` |
| Files, bytes | 53 files, 172,863,462,401 bytes |
| Indexed tensors | 1,732 in 37 shards, 170,974,427,392 bytes |
| Text tensors the stages load | 1,103, 167,264,120,704 bytes (155.78 GiB); largest 1,073,741,824 |
| Not loaded | 629 tensors, 3,710,306,688 bytes: MTP heads 1.84 GiB, vision 1.36 GiB, audio 0.26 GiB |
| Text inventory SHA-256 | `284eb2366eb7aacec0aa8362f54d195312bd2d0c2f68b3f7069e8a80add6d7d5` |

Packing: the expert banks are MXFP4, group 32, `U32` packed weights with `U8`
block scales and no biases, three tensors of exactly 1 GiB per routed layer.
Attention projections, the dense MLP of layer 0, the embedding and the head
are affine 8-bit, group 64, with `bfloat16` scales and biases. Routers and
norms are `bfloat16`; the router's score correction is `float32`. A routed
layer is 3.283 GiB (3.278 for a full-attention one), layer 0 is 0.287 GiB, the
embedding and the head 0.618 GiB each.

Shards are ordered by tensor name (layers 10 to 19 come before layer 2), so a
contiguous layer range is not a contiguous range of files. The manifest also
carries `audio_tokenizer/model.safetensors` (1.87 GB), which is not part of the
indexed checkpoint.

The manifest pin is the catalog's own manifest record. The copy the provider
writes beside a downloaded artifact (`.darkbloom-manifest.json`) is a
re-encoding with another hash; a model directory for the runtime needs the
catalog record as `manifest.json`.

Where the artifact is: on Mac A, 53 copy-on-write clones of
the operator's verified copy plus `manifest.json`, in the models directory
that holds the 9B and 27B, as `mimo-v2.6-flash-mopd-2026-09-28-r1` (no extra
disk; the operator's files were never opened for writing). On Mac B the same
directory, copied over the cable by the coordinator and verified 53 of 53,
with `manifest.json` added.

## Placement

Rank 0 holds the embedding and layers `[0, cut)`; rank 1 the rest, the final
norm and the head. The row lists cuts 16, 20, 24, 28, 30, 32, 34 and 36.

| Cut | Rank 0 tensors | Rank 1 tensors | Request state at 8,320 tokens (rank 0 / rank 1) |
|---:|---:|---:|---:|
| 24 | 76.39 GiB | 79.39 GiB | 113 / 94 MiB |
| 28 | 89.52 GiB | 66.25 GiB | 116 / 91 MiB |
| 30 | 96.08 GiB | 59.69 GiB | 137 / 70 MiB |
| 32 | 102.65 GiB | 53.13 GiB | 138 / 69 MiB |
| 34 | 109.21 GiB | 46.56 GiB | 139 / 68 MiB |
| 36 | 115.77 GiB | 40.00 GiB | 160 / 47 MiB |

The row also lists cuts 38 to 44 (rank 1 down to 13.7 GiB). Which cut a pair
loads is decided by what each Mac's memory gate admits when the session
starts: each rank needs its tensors plus about 6 GiB of loading margin.

No phase split in this rank order: the rank that decodes alone would have to
hold all 155.8 GiB, which is the single-Mac case. The row therefore lists the
pipeline and its compact decode framing only. The reversed placement (rank 0
with the lower layers on the 128 GiB Mac, rank 1 on the 256 GiB Mac, which can
hold the whole text model) is the only arrangement in which a phase split could
exist for this model; cuts 16 and 20 are listed for it. It was not built.

## What changed

Branch `work/mimo` on `e15f5b891`. `wip:` marks commits whose unit tests have
not run.

| Commit | What |
|---|---|
| `9477640c2`, `c03dcc4c0`, `b2831fb3d` | cherry-picks: per-adapter protocol policy (`7d06b0a30`), the GPT-OSS adapter case (`658ba3e64`), the tensor scope `acceptsUInt8` (`0f5fd2c48`) |
| `9279bf607` | tensor scope `indexedShardsOnly` |
| `1262599d0` | `VerifiedCheckpoint(hashingConcurrency:)` |
| `b53ffd212` | host memory gate `record` and `measure` qualification modes |
| `ff69393cf` | protocol: MiMo adapter, session lifetime per adapter |
| `1b8e9a46e` | wip: the MiMo runtime, `Models/MiMo/` |
| `abf6d70f2` | `ClusterResidentModelCatalog` |
| `5f2c53c05` | wip: MiMo unit tests |
| `5699b0542` | wip: the worker runs a MiMo stage |
| `2926d6a57`, `4baffbebb` | wip: stage check with a prefill and decode probe |
| `80d7edae6` | wip: pair driver, request and tokenizer rows |
| `f214e9add` | the MiMo section of `DESIGN-resource-gate-v3.md` |
| `40193382a` | wip: two test expectations corrected (passed on build 6) |
| `cddd9fdc2` | pair endpoint takes the model's lifetime bound (MiMo launches were refused) |

### Shared files other workers also edit

All additive; the dense paths keep their behaviour and their refusal wording.

| File | Change |
|---|---|
| `Checkpoints/SafeTensorReader.swift` | `TensorDescriptorScope.indexedShardsOnly` beside `acceptsUInt8`; default unchanged |
| `Checkpoints/VerifiedCheckpoint.swift` | `hashingConcurrency` (default 1 is the original pass) |
| `Models/Qwen/Resources/QwenDenseStageLoadResources.swift` | the watch asks the measurement object after each decision; off by default |
| `Models/Qwen/Resources/QwenDenseStageLoadMeasurement.swift` | new: `record` and `measure` modes and their report |
| `Models/Qwen/Resident/QwenResidentRuntimeQualification.swift`, `QwenResidentRuntime+Load.swift` | the gate switch is a third qualification switch, refused without the flag and honoured with it |
| `DarkbloomClusterProtocol/ClusterRuntimeCapability.swift`, `…Validation.swift` | MiMo adapter case; `maximumLifetimeSeconds` per adapter (300 unless the adapter says otherwise) |
| `Models/Metadata/ClusterResidentModelCatalog.swift` | new: every registered resident model across adapters |
| Worker: `WorkerConfiguration`, `WorkerCapabilityCommand`, `WorkerMain`, `NativeWorkerRuntime` | ask the catalog; own whichever runtime the entry names; per-model session bound |
| Qualification: `QualificationRequest`, `PromptTokenizer`, `PairConfiguration`, `PairDriver`, `PairCheck`, `StageLoadCheck` | MiMo rows and switches (`--memory-gate`, `--stage-residency`, the stage probe) |
| Check runners: worker `CapabilityChecks/run.sh` and `CapabilityCommandCheck.swift`, `PrefillScheduleChecks/run.sh`, `StartupChecks/run.sh`, `QualificationComparatorTests.swift` | MiMo's metadata in the MLX-free source closures; MiMo cases |

## What today's runtime refused, and how the MiMo row answers

| Refusal | Answer |
|---|---|
| The closed catalog has no MiMo | Its own closed row, `MiMoRegisteredSpecification`, selected by pinned configuration bytes or by model ID, and its own protocol adapter `mimo-v26-layer-stage` |
| The tensor reader refuses `U8`, and requires the shard index to equal every `.safetensors` of the manifest | `tensorDescriptors(checkpoint:scope:)`: the default scope is unchanged; MiMo asks for `U8` and for the indexed shards only, so the audio tokenizer file is hashed with the artifact and contributes no descriptor |
| Profile admission is Qwen-shaped (model type, vocabulary 248,320, GDN geometry, cuts on whole attention intervals, fusion accounting) | `MiMoRegisteredModelProfile`, `MiMoLayerStagePlan` and `MiMoRequestStateBudget`, from MiMo's own metadata; every layer boundary is structural |
| Manifest ceiling 8 GiB; loaded-tensor ceilings 4 and 8 GiB | The row's own: the manifest total itself, and no stage above the text model |
| 300 s for load plus every request | 1,800 s for this adapter, in the protocol and in the row, with the arithmetic beside it; the dense rows keep 300 s |
| Each rank hashes the whole artifact before each load | Kept. It is the largest part of a load (62.4 s on one thread on Mac B; 12.9 to 13.6 s with six files hashed at once, which is what MiMo's row asks for). Verifying only the shards a rank reads would need the manifest check to be per file set and is not built |
| The host memory gate refused a 53 GiB stage on the 128 GiB Mac | Not changed, and it was right. A qualification-only mode keeps its record; see the next section |

## The host memory gate at this size

The committed rule was not changed. `handoff/DESIGN-resource-gate-v3.md` ends
with a section holding the five loads that tested it at this size; in short:

- The rule's reserve term is the kernel's own file-cache minimum (about a
  third of memory). Loaded past it, the kernel compresses other programs'
  memory, and the growth guard (512 MiB) stopped every such load, cleanly.
- The counted-cache term over-admitted once, right after large writes by other
  copies; the guard stopped that load too.
- The 173 GB copy itself was the obstacle on Mac B: 36.64 GiB of the artifact
  sat in the file cache under the kernel's minimum. Verification and loading
  read uncached and add none. Replacing each file by a clone of itself (a
  one-off cleanup the coordinator ordered) returned 36.40 GiB as free pages.
- Which cut a pair can load is therefore decided by what each Mac admits when
  the session starts, not by its size: the placement tool chose cut 40, 38 and
  28 on the same pair within half an hour as Mac B's memory moved.

## Standing residency

A loaded stage sets MLX's per-process wired limit to its tensors plus its
request state, capped at the product's ceiling (physical memory less the
larger of 16 GiB and a tenth, and never above the recommended working set),
and restores the previous limit before the tensors are released. It is on by
default; `DARKBLOOM_CLUSTER_MIMO_STAGE_RESIDENCY=off` is a qualification
switch. The limit applied, the ceiling and the previous limit are in the load
line and in the load agreement both ranks compare.

Measured once so far (rank 1 at cut 40 on Mac B, residency on): limit
27.02 GiB of a 107.5 GiB ceiling; the Mac's wired memory 5.48 GiB before,
33.32 GiB loaded, 5.23 GiB after the process exited; limit 0 before and
after. The reading inside the process right after release still said
30.76 GiB, so the check now waits up to five seconds and reports how long the
kernel took. Not yet measured: decode without residency. Wired memory after SIGTERM
(build 7, cut 34, 512-token prefill then SIGTERM after decode step 32): Mac B
5.35 GiB before, 52.44 loaded, 4.87 one second after; Mac A 9.36 GiB before,
120.32 loaded, 10.10 one second after and 9.35 at 20 s.

## Stage loads (model level, one Mac, no collective)

| When | Rank, cut, Mac | Verify | Load | Probe (512 prefill, 64 decode) | Release |
|---|---|---|---|---|---|
| 17:44Z | 1, cut 40, Mac B | 13.6 s | 4.88 s for 26.87 GiB | prefill 2.72 s; decode median 5.19 ms a step (8 layers), first step 231 ms | 920 bytes active, 0 cached, model deallocated, nothing compressed |
| 18:54Z | 1, cut 34, Mac B (build 6) | 13.5 s | 8.50 s for 46.56 GiB | prefill 0.24 s; decode median 8.39 ms a step (14 layers) | 1,592 bytes active, 0 cached, model deallocated |
| 18:55Z | 0, cut 34, Mac A (build 6) | 26.6 s | 31.29 s for 109.21 GiB | prefill 4.16 s; decode median 16.15 ms a step (34 layers), first step 376 ms | 3,840 bytes active, 0 cached, model deallocated |
| 19:11Z | 1, cut 34, Mac B (build 7) | 13.5 s | 8.51 s | prefill 0.23 s; decode median 8.04 ms | 1,592 bytes active, 0 cached |
| 19:12Z | 0, cut 34, Mac A (build 7) | 26.1 s | 30.73 s | prefill 1.01 s; decode median 16.25 ms | 3,840 bytes active, 0 cached |

Every one of these ran with the committed memory rule recorded and nothing waived,
residency on, both Macs otherwise quiet (all four lanes held).

The probe drives one stage alone (rank 1 from a constructed residual): it is
the stage's own cost, not a correctness check. The four earlier loads that the
guard stopped are in `STATUS.md` and in the gate design.

## The pair

The first run across the cable (2026-10-09 19:13Z, build 7, `pair/pair-cut34-short-1.*`):
cut 34 from fresh device profiles (Mac A 127.87 GiB admissible, needs 115.24;
Mac B 59.26, needs 52.58), pipeline mode, prefill schedule one chunk of
serial prefill (the only schedule the MiMo row admits; the planner prints its own
choice, one chunk of lookahead, which the run does not use), committed memory rule enforced on both workers, guarded JACCL over
RDMA, all four lanes held.

| | |
|---|---|
| Request | one user turn, 27 prompt tokens, greedy, up to 64 outputs |
| Result | completed; 37 tokens, ended on end of sequence; text coherent |
| Ranks agree | both ranks report the same token chain `05dc5660…` and boundary chain `ae23d6fb…` (the report's own "ranks agree" field says "not recorded" for this model) |
| Tokens vs a reference | diverged at token 28 from the single-Mac reference (below) |
| Both ranks ready | 60.5 s after launch (rank 0 verify 26.0 s and load 31.1 s; rank 1 verify 13.5 s and load 8.4 s) |
| First token | 2.316 s (12 prompt tokens/s at 27 tokens; not a prefill rate worth quoting) |
| Decode | 21.9 tokens/s; request total 3.98 s |
| Release | rank 0 3,840 bytes active, rank 1 1,592, 0 cached, wired limit back to 0; both exit status 0; no worker left on either Mac |
| Wired memory | the driver reports +1.08 GiB on Mac A (other sessions were active there) and +0.02 GiB on Mac B |

The first attempt (18:56Z, build 6) was refused before any worker started:
the pair endpoint checked a fixed 10...300 s lifetime while the configuration
admits the model's own 1,800 s. Fixed in `cddd9fdc2`.

## After the restart (session 3, build 7, 2026-10-09 21:30-22:02Z)

Fresh plans: Mac A 185.35 / 177.09 GiB admissible, Mac B 73.36 / 72.28; the
planner chose cut 30, and cuts 30 to 42 fitted both Macs. All four lanes held,
committed memory rule recorded and enforced, residency on, serial prefill.

| Run | Cut | Prompt | Result | Ready | First token | Prefill | Decode | Peak, rank 0 / rank 1 |
|---|---:|---:|---|---:|---:|---:|---:|---:|
| `pair-cut34-short-2` | 34 | 27 | 37 tokens (eos), the same IDs as `short-1` | 65.9 s | 0.660 s | (41 tok/s) | 32.9 tok/s | 109.29 / 46.65 GiB |
| `pair-cut34-4096-2` | 34 | 4,096 | 64 tokens (length) | 60.7 s | 10.784 s | 380 tok/s | 32.7 tok/s | 110.20 / 47.25 GiB |
| `pair-cut30-short-1` | 30 | 27 | 37 tokens (eos), the same IDs as cut 34 | 56.8 s | 0.747 s | (36 tok/s) | 34.9 tok/s | 96.15 / 59.78 GiB |

Every completed run: both exit 0, shutdown acknowledged, 0 workers left on
either Mac; release lines 3,840 (3,392 at cut 30) and 1,592 (2,040) bytes
active, 0 cached, wired limit 0. Driver clock throughout; first token
includes control and transport.

- Repeats agree on tokens (`selected-token SHA c30db72a…`) and on rank 1's
  final row hash (`e784d209…`). The token *chain* differs between sessions by
  design: it is seeded with the agreement fingerprint, which includes the
  session's membership epoch. `pair-check compare` says `incomparable` for
  pair-vs-pair here only because these runs used `--evidence none` (no final
  row in the report); `--evidence final-row` would let it decide.
- **Link finding.** The first 4,096 attempt (21:32:01Z, 8 s after a completed
  run) failed before ready: Mac B `[jaccl] No IPv4-mapped GID for this
  device`; Mac B's `darkbloom cluster link` then said
  `portBridgedWithoutAddress ... its recorded address is missing`. Nothing
  was loaded. By 21:35Z the link was `ready` again without any action from
  this work. Restoring the address takes a macOS approval prompt, so a port
  that loses its address between runs breaks "approve once".
- **Fault run** (`pair-cut34-fault-sigterm-rank0-1`): rank 0 on Mac A got
  SIGTERM by hand 0.77 s after the first token of the 4,096 request (29
  tokens committed; the driver's `--fault` switch covers phase split only).
  Rank 0 ended by signal 15. Rank 1 exited by itself with status 1, but only
  when JACCL's progress timeout expired (`mesh recv: no completion for
  180001 ms`); its release line still printed (1,592 bytes, wired limit 0).
  How long a survivor waits is therefore the progress timeout the driver
  passes (180 s here, `pair-run.sh`'s default 420 s, the driver's 60 s).
  Wired memory: Mac A 10.77 GiB before, 10.32-10.81 after; Mac B 4.95 before,
  4.81-5.56 after. No process left on either Mac.

## Single-Mac reference

`darkbloom-cluster-stage-check mimo-reference` at cut 34 on Mac A (both
stages in one process, 167.26 GB active, wired limit 167.4 GB; load 84 s):

| Request | Reference | Pair at cut 34 | First different token |
|---|---|---|---|
| short, 27 tokens | 35 tokens (eos); prefill 0.27 s; decode 0.83 s | 37 tokens (eos) | index 28: reference 264, pair 279 |
| 4,096 tokens | 64 tokens (length); prefill 12.60 s (325 tok/s); decode 1.62 s (39 tok/s) | 64 tokens (length) | index 50: reference 6083, pair 2608 |

Verdict **`diverged`** for both (`reference/compare-*.txt`). `pair-check
compare` cannot read the MiMo reference's schema
(`mimo_staged_reference_v1`), so the comparator's rules were applied by a
script to what both files carry (tokens, rank 1's final row hash, boundary
chain). Neither file has logits, so whether the first difference is a near
tie cannot be shown. The pair is self-consistent (two sessions, and cut 30,
give the same 37 tokens), so the difference is between the single-process
reference and the pair: the obvious candidates are rank 1's layers running
on the M5 Max instead of the M3 Ultra, and the reference's own path. The next
step that separates them is the pair at cut 34 with both ranks on Mac A over
the local test socket, and both reports with `--evidence final-row`.

## Why the pair differs from the reference (session 4)

Step evidence (`MiMoStepEvidence`, commit `6dabfe597`): per selected token,
the digest of the residual that entered the frame, the digest of the logits
row and its four highest candidates with their exact values. The reference
records it in its report (schema `mimo_staged_reference_v2`); a pair worker
writes it as `darkbloom-mimo-step-v1` lines from rank 1 when started with the
qualification switch `DARKBLOOM_CLUSTER_MIMO_STEP_EVIDENCE=on`
(`pair-check run --mimo-step-evidence on`), and the driver keeps the lines in
its report. It is read from the bytes the row digest already copies, so it
changes no arithmetic (the recorded pair run equals the unrecorded one bit for
bit). A script in the evidence folder (`tools/ref-compare.py`) compares any
two of these reports with the comparator's rules, near tie = within 4 ulp of
the reference's top logit.

Short request, cut 34, build 8 (2026-10-09 22:21-22:45Z):

| Run | Chips (rank 0, rank 1) | Tokens | vs the reference |
|---|---|---:|---|
| reference, started with the workers' exact environment | M3 Ultra (one process) | 35 (eos) | equal to the earlier reference started with `MLX_ENABLE_TF32=1` only |
| both ranks over the local test socket | M3 Ultra, M3 Ultra | 35 (eos) | **exact**: 35 of 35 rows and every residual digest equal |
| across the cable | M3 Ultra, M5 Max | 37 (eos) | **`divergedAtNearTie`** at token 28 |

Across the cable the residuals that cross the cut are equal to the
reference's for every step up to token 28 (rank 0 runs on the same chip), and
every logits row differs from the first one on (rank 1 runs on the M5 Max).
At token 28 the reference's row has tokens 264 and 279 at exactly 23.625
(bfloat16, ulp 0.125; greedy takes the lower ID, 264); the pair's row has 279
at 23.625 and 264 at 23.5. So the code path is the same on one chip, and the
difference is the second chip's arithmetic meeting an exact tie.

The arithmetic differences that remain between the two paths, from reading
them: none in code (same session class, caches, sliding-window handling,
prefill frames, greedy selection, loader without conversion, and the residual
crosses as its exact bfloat16 bytes). The workers' environment adds
`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128` and `DARKBLOOM_BF16_WEIGHTS=1`, which
nothing on this path reads (shown above by the equal references). The M5 Max
selects other kernels for rank 1's layers: MLX's own matrix, quantized and
attention kernels with neural-accelerator variants, the MiMo prefill attention
route that is gated on accelerator availability, and device-class block
counts in the MiMo attention helpers.

## What stands between this and serving MiMo on the pair through the product

1. Tokens equal to a single-Mac reference are not to be expected on a mixed pair: a rank on the M5 Max moves logits by ulps (short request: a near tie at token 28; 4,096: token 50, not yet classified). A comparison needs the step evidence and the near-tie rule, or both ranks on one chip type.
2. The stages run the product's ordinary-cache text path. The product serves
   MiMo through its continuous-batching adapter with a paged KV pool and the
   MTP assistant; a stage on that adapter needs a residual egress and ingress
   in `libs/mlx-swift-lm`, which was not changed. The speed gap is to be
   measured, not assumed.
3. Text only: no MTP, no vision, no audio.
4. Placement has to come from each Mac's admissible memory at session start
   (the placement tool does this); a fixed cut will be refused on a busy Mac.
5. Large artifacts written through the buffer cache block the load that
   follows (gap finding in the evidence folder).
6. No coordinator or provider wiring was done here.

## Resuming

Read `STATUS.md` in the evidence folder first. Tools are in the evidence
folder's `tools/`: `build-all.sh N` (under a compile lane), `unit-tests.sh`
(under `lane.sh`), `stage-load.sh A|B RANK CUT LABEL [probe flags]`,
`stage-sigterm.sh`, `pair-run.sh REQUEST CUT LABEL`, `mac-a-slot.sh` (takes
the three Mac A lanes in order). A MiMo load on Mac A needs all three Mac A
lanes; anything on Mac B needs `lane-b.sh`.

## Not done

- The 4,096-token difference (token 50) with step evidence (reference and
  pair, `--mimo-step-evidence on`), expected to be the same mechanism.
- No probe without residency; no compact-decode mode on the cable.
- A survivor rank notices a dead peer only at the JACCL progress timeout.
- Verifying only the shards a rank reads (each rank still hashes all 53 files).
- The loader pace that was tried was removed: no dependable effect.
- Phase split, and the reversed placement that could have one, were not built.
  What the code supports today: the MiMo row lists only `pipeline` and
  `pipelineCompactDecode` (`MiMoRegisteredSpecification.swift`), the stage
  generation refuses an agreement with phase-split terms
  (`requireMiMoGenerationSource`: `agreement.phaseSplit == nil`), and the
  phase-split hand-off lives only in the Qwen dense path, where rank 1 adopts
  every layer and decodes alone. For MiMo that rank would need the whole
  155.8 GiB text model, so only the reversed order (rank 0 on Mac B with cut 16
  or 20, rank 1 on Mac A) could have it; the cuts are listed, but neither
  `pair-run.sh` nor the hold scripts launch rank 0 on Mac B.
