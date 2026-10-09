# Runtime KV quantization qualification

> Last updated: 2026-10-09

The candidate selects balanced K4/V4 attention KV by default for supported
models except MiMo. Real artifact probes measure smaller paged history and
complete encrypted checkpoints, with substantial latency costs and bounded
quality evidence. This report records implementation qualification; it does
not record a provider release or production rollout.

## Candidate and measurement method

The provider uses the [rotated affine KV format](../architecture/kv-cache-quantization.md)
in `mlx-swift-lm` commit `b02522c8569304754811d01a88b2fd086b338f2a`.
Core MLX remains `cb77239be31b1df7f5db895226af55c39fc4f093`, and MLX-Swift
remains `6923a80f624f5c91fbf456efe4e00e9698a72961`. C8 was built in the
isolated worktree before freezing an independent developer executable:

| Evidence | SHA-256 |
|---|---|
| Compiled source map | `3f986fcf1ea104783213a927113fbd4de394c36bbefa56e391cae2a14e3f65aa` |
| Provider executable | `b7c00f1dbfcba088be3c009b85f28a9a6875757561da8a6e70526c40394ee42b` |
| Source-matched metallib | `fb1ba8f90b9f1cc346246b7240c3986771464bd977c67f0ef03186811f16c85c` |

The provider source was uncommitted at capture; the complete per-file source
map binds that source independently of its earlier parent Git HEAD. Local
SwiftPM dependency paths resolve to the exact pinned SDK/core trees. These
loose qualification builds are not signed/notarized release app bundles.

The public October 9 catalog has ten non-MiMo IDs and nine distinct artifacts.
Both Gemma 8-bit listing aliases have the same aggregate. Every available
artifact file was checked against the coordinator's public manifest before
linking an owned model tree; inference recomputed the exact aggregate.
Original source caches, operator state/auth files and production services
were preserved. Tests used M4 Max and M5 Max machines with 128 GiB RAM.

The actual C8 M4 CLI also tests the base alias `gemma-4-26b` with
`--kv-backend auto` and no precision argument. It resolves to paged/balanced,
verifies aggregate `a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6`,
and exits zero after 52 tokens with a normal stop and the exact retrieval JSON.
The r2 proof records the command, report and log hashes. The earlier r1 CLI
also succeeded but its post-parser mishandled a Markdown fence; that diagnostic
is retained and is not needed for this qualifying alias result.

The [reproduction tools and manifests](../../reports/runtime-kv-path-2026-10-09/qualification/README.md)
generate four synthetic tasks: distributed retrieval, arithmetic, program
evaluation and a longer retrieval prompt. The fixed date is October 9,
sampling is greedy, the maximum output is 1,024 tokens, and the paired AR
controls disable MTP/cache reuse. Only a normal stop followed by the exact
final JSON answer passes; a truncated reasoning response fails.

Teacher-forced scores use identical token contexts, approximately 4.2k GPT-OSS
or 5.3k other-model prompt tokens and 252–255 tokens of original prose.
Each profile runs ordinary, diagnostic and repeated diagnostic forwards.
Finite logits, ordinary/diagnostic top1 equality and bit-identical diagnostic
repeats are checked separately from cross-profile drift. This ledger-to-prose
synthetic input is not a representative corpus or a general perplexity score.

## Source cohorts and transfer limits

The updated curated v8 ledger retains 148 cells in 10 stages, including superseded and
failed stages. C8 controls below are additional evidence, not silently relabeled
C3 measurements. C3–C8 per-file receipts contain 1,316 compiled-source entries; C9 adds the upstream build-environment file.

Fresh curation requires both executable and metallib SHA-256 values from each
report's mode-specific identity envelope. An independent raw-report audit
checks all 138 parsed reports: 108 generation reports with nested
`runtimeIdentity`, and 30 score reports with flat identities. Each matches
its frozen cohort artifacts; the actual alias report matches C8 too. Ten
unparsed failed cells remain failures. Missing, malformed, conflicting or
mismatched artifact identities are refused.

| Cohort | SDK head | Compiled source digest | Developer executable SHA-256 | Used evidence |
|---|---|---|---|---|
| C3 | `ac22bd62afbd7e9992f7ea556d0cebe457eb081d` | `49f91100994ffe51ee0e9a928a871fdb544382801d3707aeebeff90661e460b7` | `12f14a45e1c80e3a6ce47db836779fe896f1b59dee4a2804653a195825f69cc7` | M4/M5 task baseline; Qwen/Bonsai scores and MTP; Nemotron score supplement |
| C5 | `a571e4318ecfe359406b4a8da7af2d3dbb23a3c7` | `eafe9365859a44c2c7f8e7e13ae1caebff463b07b60873e61ec7e058c136b53b` | `f1c3c25239a78bdcaccc57d16bb3065f5d5a21e8b1d9b7de08c539292233adca` | Corrected Gemma QAT task baseline |
| C7 | `ad0e330dc7b5026d655b7bd52417bf7669596f2c` | `b290e9349127d7206af16e7801ceee3348876b0356a1bea965bd01c80a0cfa10` | `849bdce033cd00d80eb64257ec0f04116700108e6fcfe90d58d44e62d9c293fb` | M5 identical-score controls; real Gemma MTP; encrypted cache cells |
| C8 | `b02522c8569304754811d01a88b2fd086b338f2a` | `3f986fcf1ea104783213a927113fbd4de394c36bbefa56e391cae2a14e3f65aa` | `b7c00f1dbfcba088be3c009b85f28a9a6875757561da8a6e70526c40394ee42b` | KV implementation; actual B4; Gemma 8-bit pair/default alias; strict GPT cache replay |
| C9 | `b02522c8569304754811d01a88b2fd086b338f2a` | `1336e9576a8144b3ef7701769135cbb14a5bb87275dd131939ecb3106bf20024` | `faa8845e7b398fb0d8ae6a1572456893c56f7bba4bf42859607425b711fc76b2` | Merged master build/environment checks; real GPT default/auto retrieval |

C3→C5 changes six compiled-source files: packed attention/workspace/Metal,
the bounded smoke driver, and two generation-benchmark/CLI files. The independent
evaluated V-stride binding corrects the observed Gemma cold-window layout
defect; the smoke budget and benchmark changes do not establish numerical
equivalence. C3 Gemma packed results are excluded. C3 non-Gemma measurements
remain C3 observations rather than a blanket assertion about every later
branch or workload.

C5→C7 changes seven compiled-source files, covering actual-backend availability
for Gemma's ordinary MTP baseline and Diffusion whole-media quotation. The
reported target-only AR/score controls have MTP and cache reuse off. For
Qwen3.6, Qwen3.8 and Bonsai, every C7 native/balanced score arm exactly matches
its C3 M5 input hash, mean NLL, ordinary top1 array and diagnostic record bits;
Gemma QAT's two C7 score arms exactly match C5 M5. This is eight actual matching
score observations, not general cross-hardware or full-model equivalence.

C7→C8 changes exactly seven compiled-source files: `AdmissionV2`, `EngineV2`,
`PagedKVBackend`, `PagedKVQuantizationAdmission`, the historical checkpoint
producer, and the Diffusion engine/legacy-prefix restore boundaries. The
provider had already derived the packed table/minimum explicitly; the new SDK
auto-derivation is idempotent. The provider had already disabled native legacy
snapshots and the bare resident index for packed slots. Actual catalog AR
packed owners still disable ordinary successor chaining. Diffusion is outside
this catalog cohort, and its provider already refused packed legacy prefix
codecs. The current-frontier guard affects checkpoint publication, not the
cache-disabled generation/scoring controls. No attention shader, packed
transfer or model implementation changed in this C7→C8 source map.

C8→C9 merges master `cea374e88` and changes eleven compiled-source files:
the package's release-environment setting, coordinator/CDN defaults and their
CLI, download, MDM and LaunchAgent consumers. All SDK libraries and provider
inference/quantization files are byte-identical to C8. The local C9 build
explicitly selects the normal production build environment. Its real GPT-OSS
CLI run uses auto with no precision argument, resolves paged/balanced, verifies
the exact artifact, stops normally with the correct retrieval answer and
produces the same 117 generated tokens as C3's balanced retrieval. This binds
the merged provider configuration without relabeling the larger C3/C8 matrices.

These scoped facts justify retaining named cohorts. They do not promote the
failed C7 GPT cache replay into a C8 pass or claim unchanged results for all
requests. The completed Gemma 8-bit pair is measured directly on C8/M4. Source maps and record-equality
checks are independent of temporal benchmark variability.

## Model quality and storage results

| Model | Four tasks native / balanced | Task cohort/host | NLL native → balanced | Δ NLL | Top1 agreement | Score cohort/host |
|---|---:|---|---:|---:|---:|---|
| GPT-OSS 20B | 4/4 / 4/4 | C3/M4 | 5.399438 → 5.399488 | 0.000050 | 74.21% | C3/M4 |
| Qwen3.5 9B | 1/4 / 2/4 | C3/M4 | 2.663841 → 2.665802 | 0.001961 | 97.25% | C3/M4 |
| Qwen3.5 35B A3B | 3/4 / 3/4 | C3/M4 | 2.508415 → 2.516437 | 0.008021 | 95.69% | C3/M4 |
| Nemotron 3.5 Lightning | 3/4 / 3/4 | C3/M4 | 2.837215 → 2.836371 | -0.000844 | 96.06% | C3/M4 |
| Gemma 4 26B 8-bit aliases | 2/4 / 2/4 | C8/M4 | 6.908568 → 7.074352 | 0.165784 | 81.50% | C8/M4 |
| Gemma 4 26B QAT4 | 2/4 / 2/4 | C5/M5 | 6.039248 → 5.844763 | -0.194485 | 71.65% | C7/M5 |
| Qwen3.6 35B A3B | 3/4 / 3/4 | C3/M5 | 2.398041 → 2.387773 | -0.010268 | 96.08% | C7/M5 |
| Qwen3.8 27B | 4/4 / 4/4 | C3/M5 | 2.133484 → 2.150368 | 0.016884 | 95.29% | C7/M5 |
| Ternary Bonsai 27B | 4/4 / 4/4 | C3/M5 | 2.634212 → 2.608824 | -0.025388 | 97.25% | C7/M5 |

Native→balanced is a within-model pair. NLL is the mean negative log probability
of 252–255 forced continuation tokens after 4.2k–5.3k identical prompt tokens.
Top1 agreement compares ordinary native/packed predictions at those same
contexts; it is not task accuracy or a lossless-quality test. Both Nemotron
254-token score arms have finite logits, exact repeats and ordinary/diagnostic
top1 agreement. Gemma 8-bit's corrected C8 pair has finite logits and exact
within-arm repeats over 254 forced tokens, with 81.50% cross-profile top1
agreement and a +0.165784 mean NLL increase.

The failed native Gemma arithmetic/program answers remain failures. Qwen3.5
9B native retrieval/program/long retrieval truncate at 1,024 output tokens;
packed program/long retrieval also truncate. Qwen3.5 35B and Qwen3.6 program
answers truncate in both arms. Nemotron's program answers truncate in both
arms; its completed balanced long retrieval stops normally with the correct
answer. These failed task outcomes remain failures.

| Model | Task / prompt tokens | Cohort/host | Peak observed KV MiB native → balanced | Reduction | Paged committed MiB native → balanced | Reduction |
|---|---|---|---:|---:|---:|---:|
| GPT-OSS 20B | long retrieval / 15,273 | C3/M4 | 816.50 → 261.66 | 68.0% | 858.22 → 211.84 | 75.3% |
| Qwen3.5 9B | long retrieval / 19,345 | C3/M4 | 734.75 → 389.06 | 47.0% | 638.44 → 199.38 | 68.8% |
| Qwen3.5 35B A3B | long retrieval / 19,345 | C3/M4 | 517.81 → 265.35 | 48.8% | 398.62 → 124.53 | 68.8% |
| Nemotron 3.5 Lightning | long retrieval / 18,664 | C3/M4 | 206.68 → 131.56 | 36.3% | 115.55 → 36.17 | 68.7% |
| Gemma 4 26B 8-bit aliases | long retrieval / 19,347 | C8/M4 | 778.75 → 498.79 | 35.9% | 800.75 → 249.81 | 68.8% |
| Gemma 4 26B QAT4 | long retrieval / 19,347 | C7/M5 | 778.75 → 498.79 | 35.9% | 800.75 → 249.81 | 68.8% |
| Qwen3.6 35B A3B | long retrieval / 19,345 | C7/M5 | 512.19 → 265.35 | 48.2% | 398.62 → 124.53 | 68.8% |
| Qwen3.8 27B | long retrieval / 19,387 | C7/M5 | 1519.62 → 878.38 | 42.2% | 1278.62 → 399.19 | 68.8% |
| Ternary Bonsai 27B | long retrieval / 19,387 | C7/M5 | 2747.25 → 831.50 | 69.7% | 2562.12 → 399.19 | 84.4% |

The resource table uses matched long-retrieval prompts in both arms.
Host-observed KV includes native/recurrent/other owners;
paged commitment prices the physical paged allocator roots. Generated lengths
differ in several pairs, and observed peaks are not measurements at an
identical final context length. The Gemma 8-bit C8 pair completes both long
retrieval arms with 40 generated tokens and the correct answer.

| Model | Generated tokens native → balanced | TTFT seconds native → balanced | Ratio | Whole MLX peak GiB native → balanced | Cohort/host |
|---|---:|---:|---:|---:|---|
| GPT-OSS 20B | 177 → 129 | 14.38 → 51.81 | 3.60× | 14.15 → 14.20 | C3/M4 |
| Qwen3.5 9B | 1024 → 1024 | 30.99 → 66.72 | 2.15× | 11.18 → 10.99 | C3/M4 |
| Qwen3.5 35B A3B | 879 → 976 | 13.54 → 61.07 | 4.51× | 23.07 → 22.80 | C3/M4 |
| Nemotron 3.5 Lightning | 631 → 601 | 14.08 → 41.56 | 2.95× | 21.04 → 21.22 | C3/M4 |
| Gemma 4 26B 8-bit aliases | 40 → 40 | 15.99 → 104.53 | 6.54× | 28.31 → 29.04 | C8/M4 |
| Gemma 4 26B QAT4 | 40 → 40 | 5.16 → 55.63 | 10.77× | 16.81 → 17.51 | C7/M5 |
| Qwen3.6 35B A3B | 584 → 560 | 5.52 → 40.64 | 7.36× | 23.09 → 22.81 | C7/M5 |
| Qwen3.8 27B | 224 → 229 | 24.37 → 88.60 | 3.64× | 27.97 → 28.11 | C7/M5 |
| Ternary Bonsai 27B | 198 → 198 | 34.46 → 93.42 | 2.71× | 15.88 → 13.68 | C7/M5 |

These are observations from each matched prompt, not a controlled speed or
throughput comparison. The cohorts and hardware differ by row. In particular,
packing can make TTFT much larger while barely changing or increasing whole
MLX peak. No total-system memory or universal capacity gain follows from the
paged-column reductions.


The task count is a four-case synthetic denominator, not general model
accuracy. Gemma's native arithmetic/program errors and the Qwen reasoning
truncations remain failures. Similar task counts or lower NLL do not establish
lossless quality: top1 observations differ, especially for GPT-OSS and Gemma.
All retained successful score probes have finite logits and exact within-arm
diagnostic repeats.

Paged commitment and host-observed KV usage measure different owners. The
coded mirror contains every stored attention row; original recent128,
pending/prefill/speculative bands, recurrent state, native short windows and
assistant target owners remain charged. Whole MLX peak also includes weights,
activations and transient graph allocations. Host samples can miss transients.
Neither the theoretical four-bit ratio nor paged storage savings is a claim
about total model memory, system capacity or maximum context.

Timing is observational, from the production-slot report. It excludes model
loading/preflight and is not a controlled throughput benchmark. The local
launcher was paused between owned build/probe windows; wall-clock
`processSeconds` includes those pauses and must not be used as inference time.
Packed prefill and target-only decode are often substantially slower, and
whole MLX peak can rise. The original native override remains available.

## Speculative inference

The final C7 Gemma QAT run loads the manifest-verified assistant in both
arms. Adaptive execution uses the ordinary default policy. Its target-only
control uses the existing `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS=1` limit,
retaining the same assistant and its native borrowed target owners.

| Task | Prompt tokens | Generated tokens | Adaptive rounds / proposed / accepted | Control rounds | Generated token arrays |
|---|---:|---:|---:|---:|---|
| Retrieval | 4,913 | 43 | 3 / 3 / 3 | 0 | Exactly equal |
| Long retrieval | 19,347 | 40 | 19 / 19 / 19 | 0 | Exactly equal |

Both responses stop normally and return the correct retrieval answer.
Assistant config SHA-256 is `0cd54ff36e53a258532c5c1433bc44b88ba758cfe9b59bb4e6eecfd5453fabcf`;
its weight SHA-256 is `3c4d43863abbbf455ec537c726eff7abeb88bb361e3ab23ff0d2d6006f620f74`.
The adaptive controller records isolated ordinary decode costs and chooses
target-only execution when measured speculation is unprofitable; no fixed
depth was forced to obtain positive rounds.

Qwen3.6 and Qwen3.8 real-artifact C3 MTP controls also return correct retrieval
answers. Their balanced arms execute 107 rounds/404 proposals/349 accepted
and 81 rounds/218 proposals/175 accepted respectively. Rejected proposals
exercise rollback. These request-stateful controllers do not use Gemma's
target-prefix chained-baseline gate; their numerical source is unchanged.
These bounded prompts do not certify all sampling, tool or vision workloads.

## Encrypted complete cache writes and reuse

The owned C7 AES cache probe uses source digest
`b290e9349127d7206af16e7801ceee3348876b0356a1bea965bd01c80a0cfa10` and
its own frozen probe binary `58791d7aa815ea4ade9c81be274aa5a808999eb79d1c3db347f869d5b5f09395`.
These are M4 Max within-process encrypted-stage correctness tests. Invalid
macmon GPU temperature excludes performance qualification.

| Model/profile | Written files | Encrypted write bytes | Total authenticated stage-read bytes | Match M / saved per restore | Strict outcome |
|---|---:|---:|---:|---:|---|
| GPT-OSS 20B / native | 8 | 853,723,034 | 471,240,170 | 3,072 / 3,072 | PASS |
| GPT-OSS 20B / balanced | 8 | 224,567,738 | 107,896,490 | 3,072 / 3,072 | FAIL — recovered tokens differ |
| Qwen3.6 35B / native | 8 | 1,018,650,930 | 445,011,362 | 4,096 / 4,096 | PASS |
| Qwen3.6 35B / balanced | 8 | 693,591,330 | 279,860,042 | 4,096 / 4,096 | PASS |

Qwen3.6 passes strict donor, warm-tenant, cancellation/recovery, isolation and
retirement controls with matched 8-file retention, M=4,096 and three restored
contexts saving 4,096 tokens each. Native→balanced writes fall
1,018,650,930→693,591,330 bytes (31.91%) and total authenticated stage reads fall
445,011,362→279,860,042 bytes (37.11%). Each warm/cancel/recovery stage reads two
files. These byte savings belong to this matched boundary/retention workload.

GPT balanced records 224,567,738 written bytes but **fails** strict cancellation
recovery: recovered tokens differ from the completed donor. Its nominal 73.70%
write and 77.10% read reductions are **unqualified**, even though both arms
write eight files, stage M=3,072 and finish with zero KV/process-owner ledgers.
The fresh C8 M5 native/balanced GPT retake passes the unchanged strict checks.
Before inference, all ten files of public revision
`773a7da77e569019bb0fd17a554b263738d669a3` were checked against the manifest:
12,104,215,835 bytes, with exact per-file hashes and aggregate
`61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512`.
The probe uses the same C8 SDK source, executable
`aebf7d99e8f95e1cee6b1a63e0d60f3450dfa40afa441088b94f524a243ced76`
and source-matched metallib as the actual B4 probe. M4 entry refusals remain
recorded; the completed pair ran on M5 with valid entry GPU temperatures
23.675°C native and 27.374°C balanced.

| Fresh C8 GPT profile | Files | Encrypted write bytes | Authenticated stage-read bytes | Matched / saved tokens per restore | Strict outcome |
|---|---:|---:|---:|---:|---|
| Native | 8 | 853,723,034 | 471,240,170 | 3,072 / 3,072 | PASS |
| Balanced | 4 | 112,283,777 | 84,274,628 | 2,048 / 2,048 | PASS |

There are three authenticated restores per arm: warm tenant, cancellation and
recovery, each reading two files. Native saves 9,216 tokens in total; balanced
saves 6,144. The 86.85% write and 82.12% read reductions combine compression
with coarser packed capture boundaries and fewer files. They are not a
same-position payload ratio. Public DBK3 headers do not disclose exact
per-file checkpoint positions; the table uses observed restored endpoints.

The replay probe selects one public retrieval row and deliberately limits
generation to 64 tokens. Its completed donors/restores finish at `length`,
while cancellation stops after three tokens. It tests exact same-precision
replay and isolation, not semantic task accuracy. The root independently
checks all 21 exact-or-cancelled-prefix array comparisons in each arm, 92
retained file hashes, runtime/input/model identities and all 21 exposed
retirement ledgers. Pending retirement is empty. The harness does not expose
a native-generation count; its nonzero process generation field is an epoch
identifier, not an owner count. The separate 1,024-token model matrix and
normal-stop B4 responses provide semantic evidence.


Warmth here is within process with the owned ephemeral cache key. Persistent
key restart warmth, broad fleet demand gating and production write-limit
relief are not measured.


## Representative actual B4 decode

The C8 M5 Max Qwen3.6 probe verifies exact aggregate
`d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`
and C8 source digest `3f986fcf1ea104783213a927113fbd4de394c36bbefa56e391cae2a14e3f65aa`.
Its separate `radix-engine` probe SHA-256 is
`aebf7d99e8f95e1cee6b1a63e0d60f3450dfa40afa441088b94f524a243ced76`,
with the same source-matched metallib. Cache and MTP are off.

Each profile completes two batches of four requests, each with 4,916 prompt
tokens and 32 generated tokens. Native executes 5+5 completed ordinary-decode
calls at width four; balanced executes 4+4. All eight cross-profile generated
token arrays match, and within-profile repeats and all retirement ledgers pass.
All 16 raw rows finish with normal `stop`, and parsing their final JSON
returns the exact public retrieval answer:
`{"early":"cedar-0837","middle":"juniper-1942","late":"hazel-2651"}`.
They are not truncated reasoning responses. This is one bounded retrieval
task with repeats, not broad benchmark accuracy. It also proves actual
completed B4 decode; prefill/live membership varies and it is not constant B4
or a kernel-launch geometry benchmark.

| Host-observed peak | Native | Balanced | Reduction |
|---|---:|---:|---:|
| KV in use bytes | 919,797,760 | 677,110,280 | 26.38% |
| Paged committed bytes | 409,747,456 | 128,057,344 | 68.75% |

Capacity samples are 100 ms observations and can miss transients. Valid entry
GPU temperatures differ (22.996°C native, 40.609°C balanced), so elapsed
times 10.825/9.369s versus 23.454/23.794s do not support a controlled throughput
claim. Post-run artifact hashes match; no owned remote process remains.

## Regression and integration evidence

- Full provider component run: `make provider-test` passes 3,642 core tests
  across 479 suites, 552 CLI tests across 86 suites, all other target suites
  and every required isolated/fresh-process/real-allocator gate. This is C3
  evidence; later source changes have separate affected checks below.
- Final C8 provider `swift build --build-tests` completes in 78.98s. Affected
  focused checks pass 12 core functions plus two CLI functions; this does not
  relabel the earlier C3 full component run as a fresh C8 full run.
- Merged C9 provider build completes in 107.01s. Affected environment/configuration, native/packed policy, MDM, coordinator, LaunchAgent and CLI checks pass 142 functions in 15 suites plus ten functions in three CLI suites. The real default/auto GPT control also passes.
- Final SDK affected gate passes 112 functions/177 parameterized cases with
  zero skips. A removed-guard negative control fails 14 cases, and the exact
  restored source passes again. It includes all
  precision profiles/dtypes, cold layouts, original-band ownership, typed
  checkpoint aging, preflight, MTP/controller and whole-media completion.
  New direct SDK tests prove idempotent automatic packed admission, zero-cost
  early refusal of unsupported Diffusion native prefix codecs, inactive legacy
  tensor caching and real generic typed-frame restart with strict token equality.
  Actual native-owner/short-window exemptions retain native behavior.
- A real cold-window layout defect used K strides for transposed V. All 18
  dtype/layout cases fail with the old binding and pass with independent
  evaluated strides. Gemma's corrected real retrieval arms both pass.
- A real adaptive Gemma regression cannot receive chained baseline samples
  when packed retirement disables successor chaining. The old wiring fails
  the actual tiny-model engine regression with zero proposals; the final
  backend availability predicate passes while native's three committed
  chained samples remain required.
- Diffusion's accepted whole-media spans can exceed the text chunk size.
  Actual tiny packed/native engines complete prepared 529- and 1,120-token
  visual spans, with full retirement, after quoting the existing closed
  visual bound. This validates media binding/lifecycle, not vision accuracy.
- Earlier real GPU suites include 16,389-token compact Qwen4 QSA, selected
  rows/rollback/rewrite, readonly Diffusion, N17/31-buffer compilation, masks,
  sinks, softcap/GQA, exact fragmented checkpoint import and native-band aging.
- Five real macOS bundle-staging regressions pass; signed-app normalization
  preserves strict verification and development SwiftPM bundle layout.
- Frozen C5 local E2E nonstreaming, streaming and greedy determinism pass
  sequentially in 134.229s. The local coordinator/Postgres/provider testbed
  uses synthetic auth, isolated state/model/cache roots and the exact frozen
  executable/metallib; the actual backend heartbeat is paged at width eight.
  Greedy runs return the same 35 tokens. Registration took 59.095/27.039/28.035s
  per boot. These later-binary/host passes do not identify the previous remote
  CI startup failure's cause.
- The optional native MiMo retirement lane is 17/18 passing, zero skips. The
  same mixed plain/MTP timeout fixture fails at assertions 500/502/530 on the
  final code and controlled prior SDK `142fae2` with identical settings.
  MiMo and its fixtures were not changed; this baseline failure is retained.

## Final benchmark and report review repairs

C11 keeps the SDK/core and production attention/quantization math unchanged
from the measured cohorts. It repairs benchmark/report consumers of the new
default: Gate G2 forces both backend arms to native precision and uses their
observed native per-layer types; automatic E2E prewarm uses registered
`model_type` and the inherited precision while preserving exact requested
assertions and readiness; owned hosts receive the same public precision key.
Diffusion rows retain numeric usage `promptTokens` and export IDs separately
as `promptTokenIDs`. Signed scheduler decision schema 4 binds actual
constructed precision to every result and the run identity, rejects missing,
unknown, mixed or backend-incompatible precision, and revalidates decoded
reports through the existing model/binary/source gates. Legacy schema 3 remains
readable but unqualified. These changes do not constitute new model accuracy
measurements or signed release qualification.

C11 compiled-source digest is
`1c3f7fe4d6c2784af0955cf6ca7a10aab90ea87a67097e242039da94bc1d39f9`;
its developer executable is
`00f35e723a17951fb0c033c15c2dc5399d796c55e1041093f012ca56f993528b`.
The 1,319-source map reconstructs from C9 with fourteen benchmark/report
changes. The model/scoring/SSD write tables retain their named cohorts.

A real C11 GPT Gate G2 run under ambient `balanced` constructs native
contiguous and native paged engines with observed mixed native storage.
Three prompts produce 24 identical raw generated tokens, eight per row with
matching `length` finishes. One criterion is evaluated and passes. Four are
unavailable: no MTP assistant, no model packed-prefill claim, no vision-span
support, and a short prefix below the 1,536-token frozen replay bound. The
separate FP32 diagnostic is refused or non-perturbing under the unchanged
native-dtype guard. This bounded token-exact result is not semantic task
accuracy, packed-quality qualification or a complete Gate G2 qualification.
Earlier C10 real GPT/Gemma probes with the historical FP16 pin were
inconclusive; their native contiguous construction worked, but the strict
paged native-dtype guard refused the mismatched pin. Those results remain
retained and do not become passes.

Controlled reinstatement of the original Diffusion usage overwrite and
missing parity native pin produces seven assertion issues across the nineteen
two-suite regressions. The exact positive source is restored byte-for-byte.
The final affected gate passes 152 core functions in nine suites and five
CLI functions in one suite, with no skipped affected tests. The full Go
testbed suite, four benchmark posture/control functions and seven workflow
functions pass. The combined build is 73.60s; the restored and native-dtype
builds are 7.71s and 27.40s, followed by a 30.60s test-only rebuild.
The Go old blanket-paged expectation and dropped owned-host precision controls
also fail meaningful assertions, with exact source restoration. Final local
and remote validation is tracked in the PR; no unavailable criterion or earlier
failure is silently counted as a pass.

## Retained failed stages and limits

C3 Gemma packed startup refused its underquoted 64 MiB synthetic smoke pool;
the bounded smoke fixture was corrected to 128 MiB against the measured
window gather quote. Production memory safeguards were not lowered. C4 Gemma
then exposed the cold V-stride defect and failed all four packed tasks;
those results are superseded, retained, and excluded from quality claims.
C5 Gemma's MTP-active flag hid zero actual proposals because the chained
baseline was unavailable; C7's real rounds and matched control replace that
diagnostic result. Earlier construction/Metal binding failures remain in the
owned logs. Passing later stages do not turn earlier failed gates into passes.

Packed slots bypass untyped native tensor snapshots and the bare resident
page index. Eligible AR typed complete checkpoints include coded bytes and
the exact original band. Diffusion's separate legacy resident/durable native
block codec remains `unsupported_layout` under packed precision. MiMo stays
native before precision override parsing, including malformed overrides.
There is no universal model-quality, speed, total-memory or fleet-write-rate
claim. Release app signing/notarization, broad benchmark quality, production
traffic, persistent-key restart warmth and fleet demand gating are separate
qualification boundaries.

## Evidence

Raw results remain in task-owned local/remote qualification directories. The report
reads `curated-progress-v8.json` (148 cells/10 cohorts), each named cohort's
`run.json` and score/generation JSON, `candidate-03/05/07/08/source-receipt.json`,
`gemma-mtp-comparison.json`, `encrypted-cache-probe/c7-cache-summary.json`, and
`width-four/summary-proof-c8-b4.json`. The updated C3 M4 cohort has 60 retained
cells, including both complete Nemotron scores and its balanced long retrieval.
The curation SHA-256 is
`7e0432fac3572d282209ce08b977111f1bc7ca65a11e85b98f9358e99c228191`.
`report-cohort-proof.json` records the three per-file source-map transitions,
all eight exact M5 score-arm comparisons, all 16 B4 expected-answer checks,
the C8 Gemma 8-bit score pair and the actual base-alias default CLI proof.

The fresh C8 M5 encrypted-cache pair, raw commands, input, headers and
retained ciphertext inventory are bound by the final summary and independent
audit below. Ciphertexts and model weights stay in their owned remote roots;
the bounded local archive contains 93 evidence files, including a 92-file
content-hash inventory. C7's failed packed replay remains unqualified. C9's
source delta reconstructs the merged provider source from the full C8 map.



Portable report evidence is collected under
[qualification/evidence](../../reports/runtime-kv-path-2026-10-09/qualification/evidence):

- [Curated runs](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/curated-runs.json), retaining failed and superseded stages.
- [Source cohorts](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/source-cohorts.json) and [scoped cohort comparisons](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/cohort-proof.json).
- [C7 encrypted cache](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/encrypted-cache-c7.json) and [C8 encrypted cache](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/encrypted-cache-c8.json).
- [Gemma MTP](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/gemma-mtp-comparison.json), [actual B4](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/width-four-c8.json) and [default Gemma alias](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/gemma-base-default-c8.json).
- [Independent artifact identity audit](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/artifact-identity-audit.json).

- [C8 independent raw-token/hash audit](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/encrypted-cache-c8-audit.json), [reported retirement ledgers](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/encrypted-cache-c8-retirement.json) and [ten-file M5 artifact verification](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/gpt-artifact-m5-verification.json).
- [Merged C9 default/auto GPT control](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/gpt-default-c9.json).

- [C11 bounded native Gate G2 report](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/native-g2-c11.json), [execution identity](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/native-g2-c11-execution.json) and [controlled review regressions](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/review-negative-controls.json).

- [C11 review repair validation](../../reports/runtime-kv-path-2026-10-09/qualification/evidence/review-repairs-c11.json).
