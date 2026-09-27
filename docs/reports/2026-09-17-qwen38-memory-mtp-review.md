# Qwen 3.8 Next: loading and MTP memory review

> Last updated: 2026-09-17 · commit `77d1d1d86`

This is a scoped review checkpoint, not an all-gates production sign-off.
The implementation is native Qwen4. Trained weights, quantization, tokenizer,
embedded heads and default SSD PLE offload are unchanged.

## Bound publication inputs

- Provider runtime source: `77d1d1d86ea743887526d4b0c93a362e0eb4212c`.
- SDK: `ae3ecdc835a895091f8929749fdb3e14383295a9`.
- Selected artifact revision: `e555958420096f695d449111693a6647b698479b`.
- CLI SHA256: `a4d3ad0db52965127af9667b6851bceb4fc04d00d2008c3bc962da1179b7567a`.
- Target-built metallib SHA256: `38ceb8a1113b373ccaa89355d895fc8ded3bafc81076dc4ffdb426e2eee03a93`.
- Qualification host: M5 Max, 128 GiB. Release products were built on M3 Ultra
  with the same Swift 6.4 toolchain and locked dependencies, then hash-verified
  for M5 execution. A transferred XCTest resource-path failure was retained;
  correct resource placement allowed the same binary to pass its model tests.
- Composed receipt SHA256: `ff8fdd9aa94cde25f29c60d91d8c41922480985dbdd34752d660ab2a8ac021e2`.

The provider includes upstream's console-key security update. Its single merge
conflict was documentation metadata. Private prefill, counting-sort, lookahead
and NAX experiments are excluded from this publication tree and history.

## Changes

The native loading bound replaces generic 20% padding only for validated,
eligible SSD-offloaded Qwen4 layouts. Complete headers/indexes, all compute,
vision and MTP payloads, native-copy envelopes and page rounding are checked.
Unknown or unsupported layouts retain their previous estimate. The selected
checkpoint uses about 69.2 GiB of MLX weight residency; its declared loading
allowance is 75.026 GiB and total admission is 81.526 GiB, including unchanged
serving headroom. Preserve the earlier 89.5 GiB requirement and failures as
historical evidence, not a pass under an unchanged estimate.

After owned Qwen4 retirement, insufficient admission can resample actual OS
headroom for at most two seconds. The allocator and Metal can report release
before macOS finishes reclaiming physical pages. The fix grants no guessed
memory credit and lowers no OS, activation or KV reserve. The original quiet
cancellation/readmission/unload/reload body passed on the same loader code;
it retains inner-owner, PLE, ledger and exact-output checks.

MTP catch-up is bounded to 2,048-token chunks. Cold and restored unprimed heads
use consistent carry initialization; primed caches remain intact. Native
selected-page reads and grouped gathers avoid unnecessary full-history reads.
Explicit rollback controls remain available. Draft proposals can differ;
target verification, committed output and complete state must remain exact.
The observed excess was transient work/storage, not three copies of the model.

## Results and limits

| Gate | Result |
|---|---|
| Narrow package CPU builds, coordinator and docs | Pass |
| M5 focused default/attention/MTP gates | 10 XCTest and 28 Swift Testing cases pass; no skips |
| Full-weight native state and output budgets | Two tests pass; retained/rejected state, trained-head replay/discard, serialized suffix and budgets 1–9 |
| Local Chat/Responses/tools/reasoning OFF/ON | All 118 required cells pass across MTP OFF/AUTO; two optional compatibility probes remain separately classified |
| Responses-to-Chat history replay | Eight paired cases pass across both MTP modes |
| Mixed queued text/tool/image comparison | Four concurrent HTTP requests match isolated outputs; native multirow remains disabled |
| Artifact integrity | Complete 35-file readbacks before and after the composed run pass |
| Full cached lifecycle | **Fails at repeated-request cache usage**: output matches the uncached reference, but cached tokens are zero; later lifecycle cells did not run |

A separate, unchanged-candidate diagnostic observed zero cached tokens cold,
then 6,144 on three repeats, the first immediate, with identical output/usage.
That proves cache capability, not a fix for the full-sequence miss. The miss
occurred in both the pre-publication and clean publication sequences. Its cause
remains open; neither an arbitrary delay nor a claim of model corruption is
supported. Ready status is not proof that an individual checkpoint was imported.

Earlier same-path M5 qualification also passed 24 encrypted loopback WebSocket
cells and repeated physical load/reload checks. Synthetic identities do not
establish production account authentication or attestation. Local compatibility
is not hosted OpenRouter certification.

The earlier complete default M5 SDK run retains 16 XCTest failures and 297
Swift Testing issues at exactly the pre-existing locations/counts. The provider
run retains 129 generic CBv2/GPT-OSS numerical issues. A precise-math diagnostic
passes but is not the serving default and does not erase those failures.
Do not check the overall required release-gates box from this report.

## Bounded performance

The clean publication package's cache-OFF client-clock checks preserve all
reference outputs, usage and finish reasons. The 4,228-token, 192-output-token
counting fixture measures 43.1–43.5 tok/s OFF and 78.6–78.9 AUTO with full
acceptance. The prose fixture measures about 42–43 OFF and 47–51 AUTO with
61–66% acceptance. These are first-to-last output proxies, not universal agent
throughput or GPU-only timings.

Before removing dormant experiments, the same active MTP mechanisms measured
67.6 tok/s for 20K input/512 output and 57.3 tok/s for 79K input/192 output,
both with full acceptance and matching OFF outputs. The latter peaked near
81 GiB; an earlier whole-history replay baseline peaked near 93 GiB at 63K.
These longer-context results remain bound to their original candidate, not a
claim that every workload was repeated on the publication binary. The serving
envelope tested here is not the model configuration's full 262K limit.

Prefill remains below the requested reference target. Neither a 1.2K–1.4K
sustained prefill claim nor a 2.5K claim is established by these measurements.
Further prefill candidates require their own exactness and composed gates.
