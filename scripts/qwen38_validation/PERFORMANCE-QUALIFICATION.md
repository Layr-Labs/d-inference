# Qwen 3.8 Next / native Qwen4 performance checkpoint

> Recorded 2026-09-14 · private review; no release or default activation

The subsequent [clean-source revalidation](REVALIDATION-20260914.md) records the
final fixture corrections, rerun counts, refreshed speeds and cache results.
This earlier checkpoint retains its original artifact and execution scope.

This checkpoint retains native multimodal Qwen4, embedded trained MTP, SSD
n-gram/PLE, paged ownership and complete prefix state. It adds qualified opt-in
attention/submission improvements on top of the canonical media-prefix fix.
It does not establish universal answer quality or completion of the40/66–88
tok/s goal. Public submissions remain frozen pending human review.

## Runtime identity

| Input | Recorded identity |
|---|---|
| Provider runtime base | `db08d74974cbed922f671aa1e950d8b607e567ce` |
| SDK runtime base | `d41be4f88a31db99f7727a0e6fff029ad31ab9d6` |
| Qualified four-file SDK patch SHA256 | `afdd5eb45e89ae547b8b28b34ce656b6cdfdd78f6836cd3655db95a2b542f0d1` |
| Production executable SHA256 | `3ac76ef3e9bade476fb2e21d71cab25c4211bc49cc39681fced25678cea808b8` |
| Metallib SHA256 | `2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2` |
| Provider Package.resolved SHA256 | `b2b12d24d48bbedc4583d8831e0b81fe68b96d641804e0ebc56715cd2d88a7ea` |
| Model config SHA256 | `f04c5e8f500fe880617bf10a4ac6efc063b6ef8dbe66fb6a4843407c18ce7dae` |
| Model index SHA256 | `7fccee8cf9d3b2a7af16e34dec85ccd3558bb3aa7a399ab9eee2b3211cd8fbde` |

Foundation pins remain core `3fa8f25e`, Swift `6d6796d7`, C `02cf6f4d`.
The private review packages the exact runtime patch plus a test-only follow-up
in SDK commit `141e067e1527b004cd9aa7de6d432cfd68f040f0`, pinned by this provider's
gitlink. Runtime code is unchanged from `6445eeb129f7131f3d510e79be61052998ae8d36`.
The public submodule URL must not be used to claim that private commit is
available publicly; authorized public promotion requires an observed public
SDK commit, consumer repin and re-verification.
Production command: `swift build -c release --product darkbloom --jobs 8 --disable-automatic-resolution`.
Four adjacent resource bundles and the matching metallib are required. Test
executables are distinct artifacts, not substitutes for this release binary.
The provider runtime sources and manifest are unchanged; this review adds a
matching SDK pin, exact qualified test sources, portable fixture generation,
validation-only fixes and documentation. Runtime-tree equality binds existing
evidence; it is not a claim that each documentation-only commit was rebuilt.
Fresh composed-build/CI evidence remains a distinct pre-promotion check.

## Enabled paths and rollback

The qualified settings are `DARKBLOOM_QWEN4_QSA_PARALLEL_FULL_KV=1`,
`DARKBLOOM_QWEN4_QSA_PARALLEL_VALUE_PARTITIONS=32`, and
`DARKBLOOM_QWEN4_LAYER_ASYNC=1`. Both new switches default OFF in source.
The first reuses parallel QK tiles with ordered softmax/PV on existing full KV.
The second submits valid singleton native paged text layers early at widths1–6,
with whole-bank fault checks and deferred-fill resolution. Explicit positions,
embeddings, unsupported caches and wider/batched shapes retain old scheduling.
No approximation, selector/precision change, state omission or MTP controller
change is included. Disable both switches to restore old dispatch/scheduling.
Revert SDK/provider pins together if reverting commits. No model or cache
deletion is required; existing canonical media-prefix identity remains intact.

Grouping multiple layers per submission gave no consistent material gain and
is excluded. Selected-KV component proofs are not full-model speed qualification
and are excluded. Neither experiment changes this checkpoint's defaults.

## Measured speed, scope and exactness

Same7041-token synthetic code input,192 outputs, cold native prefix state,
two interleaved repetitions per arm, full-KV parallel enabled throughout:

| Mode | Layer submission OFF | Layer submission ON | Accepted/proposed |
|---|---:|---:|---:|
| Target-only |27.222 /27.192|37.035 /37.053|No MTP|
| Fixed depth2 |46.474 /46.359|59.473 /59.983|122/136,89.706%|
| Fixed depth4 |52.458 /52.602|63.340 /63.625|142/192,73.958%|

Rates are native decode tok/s. Prefill889–906 tok/s; no cached-token credit.
Every arm retained the same golden192 tokens and same-depth MTP traces; output
SHA256 `10b1b385bbd0179f529afa0c46b1064397bde3844c8b73ae41dcdfe7897608b5`.
Normal production HTTP measured35.957/36.554 OFF and54.457/62.086 AUTO with
prefix OFF; these are client proxies, not native clocks. Clean cached AUTO
measured53.759/59.725; repeat6144 cached tokens reduced TTFT7.771→1.238s.
Adaptive-depth variability remains. No sustained66+ or cross-engine parity claim.

## Executed gates

- Full provider defaults and enabled: each111 XCTest (103 pass,8 skip) and
  2950 Swift Testing (2898 framework pass records,52 skip), zero failures.
  Ten entitlement early-returns are not hardware passes. Four isolated groups
  execute five additional tests with zero skips in each arm.
- Full SDK defaults and enabled: each884 XCTest (875 pass,9 skip) and1223
  Swift Testing (1209 pass,14 skip), zero failures. Applicable isolated native,
  allocator/admission, PLE, dispatch-scope and video-frame gates also passed.
  Unrelated real-artifact tests remain unexecuted.
- Full-KV numerical proof:360 exact cells, actual dispatch360, two tests.
  Layer safety:four tests including late faults after valid submissions and
  same-ID recovery. Miniature native state:104 exact cells. Full-weight native
  retained/rejected/serialized suffix:25 cases. Output budgets1–9 match target/MTP.
- Local standard Chat/Responses/tools/reasoning:59 required cells per OFF/AUTO
  arm, plus separate expected unsupported-high refusal.81K context parity and
  cached lifecycle9/9 pass. This is local OpenRouter compatibility, not a hosted
  provider route or account/attestation certification.
- Encrypted Chat streaming over actual loopback WebSocket:reasoning OFF/ON ×
  MTP OFF/AUTO,24 cases, exact content/tool values/usage/terminals. Eligible AUTO
  requests demonstrate proposals. Required/named constraints remain target-only;
  media remains target-only. ON emits separate reasoning, but matching reasoning
  counts are not a hidden-reasoning byte-hash proof. Responses/media transport
  require their own connected-transport coverage.
- Quiet prefill cancellation, drain, readmission, unload/reload and native/PLE
  ownership passed. Media-cache mechanisms14/14 reference and18/18 cached pass,
  including changed-media/order misses and text MTP after media. Against the
  old runtime and between OFF/AUTO:65 standard API/media outputs and18 successful
  strict-fidelity outputs match; original generated histories replay2/2 per arm.

Original failures/skips remain in the private evidence ledger. In particular,
the clean enabled SDK suite exposed a50ms-dependent packed-vision fixture: all
reference tokens matched, but arrivals split into one-row/two-row batches rather
than the required three-row batch. The test now queues all synthetic submissions
before stepping, retaining the exact[3,16] and output assertions. No production
scheduler/model changes. Require fresh isolated and full-suite checks; a lucky
rerun does not close the preserved failure.

Separately,
the first cached lifecycle attempt used an obsolete text-only refusal oracle.
The corrected harness requires artifact-selected supported/unsupported media
before testing; it never accepts whichever status arrives. Four new pure oracle
tests preserve the refusal branch and reject speculative media or invalid200s.

The clean release provider suite also exposed three updater-fixture failures
caused by a hardcoded debug-product lookup. Test discovery now uses the active
test bundle's debug/release configuration, including custom scratch paths, and
refuses missing/peer-configuration products. Location tests retain negative
cases, while updater/runtime-smoke checks must execute on matching products.
Only test helpers and documentation change; runtime sources and model bytes do
not. Ad-hoc signing of temporary test fixtures is not production signing/trust
qualification. Preserve the original missing-file failures and rerun the gates.

## Open quality and release gates

- [ ] Strict payload fidelity:5/20 quality passes per arm,18/20 wire-valid,
  20/20 correct constraint posture; two HTTP422 refusals persist. Equal wrong
  answers are not quality passes; do not repair model-generated values.
- [ ] Standard multimodal answer quality:16 pass, two existing failures and
  one dependent failure. Media-reference/cached matrices retain five/six
  answer-quality failures despite passing their mechanism checks.
- [ ] Sustained requested contexts/agentic workloads at40 target-only and
  66–88 MTP tok/s with high acceptance; current bounded results do not close it.
- [ ] Fresh clean composed build/CI before public promotion; physical promised
  hardware tiers, signed persistence/trust, hosted routes and release operations
  need separate evidence and authority. No new BF16-equivalence claim.
- [ ] All required end-to-end release gates complete, with current evidence.

## Portable reproduction

Use the [validation guide](README.md) and its external configuration contract.
Never load the HTTP endpoint, oMLX or another GPU test concurrently. Build tests
with `swift build -c release --build-tests --jobs 8 --disable-automatic-resolution -Xswiftc -enable-testing`,
then place the matching metallib beside the discovered test executable.

- `Qwen4SparseParallelProbeTests`: set `DARKBLOOM_QWEN4_PARALLEL_PROBE=1` and
  `DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST=1`; run alone, require2 passes/0 skips.
- `Qwen4LayerSubmissionSafetyProbeTests` and `Qwen4LayerSubmissionStateProbeTests`:
  set `DARKBLOOM_QWEN4_LAYER_SAFETY_PROBE=1` plus the exclusive flag; run separately,
  require4 and1 passes respectively, zero skips.
- `Qwen4FixedDepthPerformanceProbeTests`: generate a new input with
  `python3 -B scripts/qwen38_validation/make_fixed_depth_fixture.py --output /absolute/new-input.json`.
  Set `DARKBLOOM_QWEN4_FIXED_DEPTH_PROBE=1`, `DARKBLOOM_QWEN4_FIXED_DEPTH_AXIS=layer`,
  the exclusive flag, `DARKBLOOM_PREFIX_CACHE=0`, `DARKBLOOM_PREFIX_CACHE_MEMORY=0`,
  and externally supplied `DARKBLOOM_QWEN4_REAL_MODEL`,
  `DARKBLOOM_QWEN4_FIXED_DEPTH_INPUT`, `DARKBLOOM_QWEN4_FIXED_DEPTH_OUTPUT`.
  The output directory must not exist. Preserve default SSD PLE residency and
  exact config/index identities; require1 pass/12 arms and zero skips.

Run real-state/budget, connected transport and full suites as separate gates
described in the validation guide. A filtered proof is not the full suite.
Retain source/binary/resource hashes and passes, failures, skips separately.
