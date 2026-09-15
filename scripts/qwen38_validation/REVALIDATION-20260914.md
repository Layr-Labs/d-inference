# Qwen 3.8 Next / native Qwen4 — clean-source revalidation

> Recorded 2026-09-14 · private review only; not public promotion or deployment

The qualified full-KV attention and early-layer-submission baseline was rebuilt
from clean, pinned source and revalidated through the native d-inference stack.
Weights, quantization, embedded trained MTP, full multimodal processing, SSD
n-gram/PLE and runtime safety gates are unchanged. This is not a27B model or a
Qwen3.5 architecture alias.

## Exact source and artifacts

- SDK runtime/fixture commit: `141e067e1527b004cd9aa7de6d432cfd68f040f0`.
- Provider tested source: `a6c8fb9838f2957167b0b3975f2c08d864aa044f`.
- Production binary SHA256: `c60bb5e961617c05fe7e63231ed7fbb40902b0938515449b03a234ccfb7abdfe`.
- Metallib SHA256: `2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2`.
- SDK test binary SHA256: `259cdcf182941969e6b9183adb0d44216c0712b0cdeee1b37c529690cf2c5e18`.
- Provider test binary SHA256: `f65d0ecb7dc44e40fe8fc3ddc0bad5727bcd5b0c9d62c1c52a0d74e4e0ee63c6`.
- Foundation pins: core `3fa8f25e`, Swift `6d6796d7`, C `02cf6f4d`; all36
  provider and37 SDK dependency revisions checked. Provider lock SHA256:
  `b2b12d24d48bbedc4583d8831e0b81fe68b96d641804e0ebc56715cd2d88a7ea`.
- Model config/index SHA256:
  `f04c5e8f500fe880617bf10a4ac6efc063b6ef8dbe66fb6a4843407c18ce7dae` /
  `7fccee8cf9d3b2a7af16e34dec85ccd3558bb3aa7a399ab9eee2b3211cd8fbde`.

The production build records provider `ac3d606b`; its subsequent exact five-file
delta to `a6c8fb98` contains only provider test helpers, their tests and docs.
All production inputs, SDK and foundation pins remain unchanged. This checked
equivalence preserves the original build identity; it does not relabel a binary
as rebuilt. The affected provider test executable was rebuilt. Later report-only
packaging must likewise preserve runtime/test input identity.

## Corrections found during clean revalidation

1. A generic packed-vision fixture used a50ms delay to expect one three-row batch.
   All reference tokens matched, but one full run produced one-row/two-row batches.
   It now queues the synthetic admissions before stepping through the existing
   engine-queue test seam. Exact[3,16] and output assertions remain. Five isolated
   runs per optimization posture passed, followed by both full SDK suites.
2. Updater tests looked only in `.build/debug`, hiding their dependency on old
   local artifacts. They now resolve child binaries/resources from the running
   test bundle's actual configuration. Debug/release/custom-path, missing-peer
   and traversal checks pass; all21 updater/runtime-smoke tests pass. The new
   directory-URL expectation explicitly declares its directory hint. No runtime
   scheduler, loader, signing policy or model code changed.
3. The private results parser now recognizes singular `1 failure` as well as
   plural summaries. The original failed receipt remains unchanged with a
   separate count correction; process exit1 had already failed that run.

Temporary ad-hoc test-app signing is not Developer-ID, attestation or release
qualification. Original failed runs are preserved, not erased by reruns.

## Executed native and provider checks

- Full SDK defaults and enabled, each:875 XCTest passes/9 skips and1209 Swift
  Testing pass records/14 skips; zero failures.
- Full provider defaults and enabled, each:103 XCTest passes/7 skips and2900
  Swift Testing pass records/51 skips; zero failures. Ten entitlement-dependent
  early returns remain unqualified, even though the framework reports them passed.
- All13 selected SDK opt-in groups pass without skips: native components,
  cross-model dispatch isolation, SSD PLE first use/bit equality/retirement in
  both postures, allocator/admission/decode invariance, actual full-weight
  retained/rejected/serialized state, embedded-head replay/discard, output
  budgets1–9 and native20-frame video extraction.
- Full-KV attention360 exact FP16/BF16 cells with real dispatch; four layer
  fault/deferred-fill tests;104 miniature native-state cells pass.
- Actual quiet-prefill cancellation observed two steps/20,426 active tokens,
  zero output, complete drain/readmission/unload/reload and PLE owner release.
- Actual encrypted Chat WebSocket transport:24 cases across reasoning OFF/ON
  and MTP OFF/AUTO pass, including plain/auto/required/named/none/history, exact
  tool values, usage and terminals. Eligible AUTO requests show real proposals.
  Required/named constraints remain target-only; reasoning OFF emits no reasoning
  or internal framing. This is not hosted OpenRouter or real-account attestation.

## Fresh production HTTP results

- Nine matched production probes pass in both MTP OFF and AUTO with actual
  optimized-path witnesses, identical outputs/finishes/counts and no cache credit.
- Both arms pass all59 required local Chat/Responses/tool/reasoning cells plus
  the separately expected unsupported-high refusal,81K context and uncached
  lifecycle references. ON context content/finish/usage matches OFF exactly.
- Across OFF/AUTO and versus the previous qualified build:65 comparable
  successful API/media outputs match. Two generated-history inputs differ and
  are kept separate; original real-generated histories replay2/2 exactly in each
  arm. Refusals are not successful-output comparisons.
- Strict payload fidelity retains5/20 quality passes,18 wire-valid outputs and
  20 correct constrained postures per arm, with the same two HTTP422 refusals.
  All18 successful outputs match exactly across arms and the prior build.
- Standard multimodal retains16 passes, the same two answer-quality failures
  and one dependent-history failure. Image resolution/order/history and ordinary
  video pass. Correct frame extraction does not waive wrong visual answers.

## Cache completion checkpoint

Fresh media-reference mechanisms pass14/14; cached mechanisms pass18/18,
including changed image/order/clip misses,4096-token hits beyond media,
cancellation/readmission and resumed ordinary text MTP. Outputs and token usage
match the uncached references. Five/six respective answer-quality failures
remain, so overall media quality is not marked passed.

Fresh cached lifecycle passes9/9: cold/repeat/suffix, cancellation, drain,
readmission, legal half-close, explicitly supported image input and final drain.
The repeat code probe reused6144 tokens and reduced TTFT7.681→1.244s, with exact
output parity. Cached AUTO client proxies were55.04/59.86 tok/s. The cache key
is ephemeral for local validation; this is not signed persistent-restart proof.

## Matched speed and losslessness

Apple M3 Ultra,256 GiB. Same7041-token synthetic prompt,192 outputs, two
interleaved repetitions per arm. Native prefill897–917 tok/s without cache credit.

| Decode mode | Layer submission OFF | Layer submission ON | Accepted/proposed |
|---|---:|---:|---:|
| Target-only |27.70 /27.65|37.35 /37.66|No MTP|
| Fixed depth2 |46.28 /47.39|59.96 /60.06|122/136,89.706%|
| Fixed depth4 |53.57 /53.30|64.16 /64.22|142/192,73.958%|

Every arm retains golden token SHA256
`10b1b385bbd0179f529afa0c46b1064397bde3844c8b73ae41dcdfe7897608b5`
and identical same-depth proposal/acceptance traces. Production HTTP client
proxies were36.45/37.46 OFF and53.43/61.36 AUTO. Client proxies are not native
engine clocks. These results confirm the prior qualified improvement; they do
not establish universal40/66–88 performance or oMLX parity across workloads.

The qualified switches remain explicit opt-ins: full-KV parallel attention,
PV32 and early layer submission. Both new master switches default OFF in code;
the local validation profile enables them. No fleet default is changed here.
Multi-layer cadence and selected-KV experiments remain excluded.

## Review boundary

- [ ] Remaining exact-copy/visual-answer quality failures are not waived.
- [ ] Sustained40 target-only/66–88 MTP across requested workloads remains open.
- [ ] Physical promised tiers, signed persistence/trust, full connected
  Responses/media transport, hosted routing and remote CI need separate evidence.
- [ ] All required end-to-end release gates complete, with current evidence.

This dated record does not grant publication authority. The September 15 draft
update publishes the reviewed changes while preserving the limitations here;
merge, model visibility, R2, catalog activation and deployment remain separate.
