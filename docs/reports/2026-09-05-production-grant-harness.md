# Production-grant benchmark and restored-prefix cancellation

> Last updated: 2026-09-05 · commit `aaa710c44`

The direct benchmark can now derive a single loaded model's KV grant from the
production memory policy. Its cancellation probe completes a donor in the same
scope, then requires actual SSD restoration before cancelling a paged cache-on
request. The provider CLI and standalone benchmark release builds pass. These
are build and harness gates; model performance is measured separately.

## Production grant and controls

`--production-kv-grant` uses loaded target and prepared assistant parameter
bytes, the resolved unified-memory cap, operator and serving-set activation
reserves, zero RAM prefix allowance and the normal one-slot reslice policy.
It records every input and the resulting grant. It retains a separate measured
post-build OS/activation serviceability check; a logical grant cannot waive
insufficient live headroom. Shared process authority uses the same cap/reserve.

`--kv-budget-gib` remains the explicit envelope control, with its existing
16 GiB default and measured post-load guard. It cannot be combined with
production grant mode. Resident reproduction, native-type-only probes and
injected multi-session budgets cannot use the production single-slot mode.
B1/B2/B4 changes request concurrency, not the number of loaded models.

Reports and comparators require consistent policy inputs, actual engine grant
and post-build headroom. They keep native committed backing separate from the
logical grant. This SPI still measures direct engine submission: provider
bridge admission, local HTTP and connected routing require their own tests.

## Cancellation probe

Version 2 completes a donor in the exact cancellation scope in both cache arms.
Paged SSD cancellation then requires a staged hit, positive matched and saved
tokens, and a fresh authenticated SSD read-byte increase. Cancelled output must
match a donor prefix; recovery must reproduce the donor's full token sequence.
A naturally completed donor remains reusable after cancellation. Version 1
reports retain their older cold-cancellation meaning and cannot be mixed into
a version 2 comparison. A short input below cache policy thresholds cannot
prove restore cancellation; include an eligible control.

Initial, running, completed, failed and aborted donor cells remain in partial
reports. A fast natural completion does not pass cancellation. Python checks
reject missing donors, mismatched scope/prompt/tokens, absent actual read/saved
work, invalid versions and false cache-off hits.

## Validation and source lineage

The provider semantic gate passes **124 functions/cases** across grant,
production input, MTP benchmark and parity groups, including three new grant
tests. The provider build took 97.42 seconds. The final Python harness covers
**40 test functions**; the standalone compiler fixes do not change that Python
source. Provider and native production source remain identical to the accepted
semantic candidate.

The release CLI compiled in 324.66 seconds. Its first verification wrapper
stopped on `/tmp` versus `/private/tmp` source spelling after successful
compilation. The retained addendum resolves those paths to the same hashed
files. Standalone attempt 2 found three harness compilation issues: a
module/type name collision, a missing file-local benchmark SPI import and a
non-Sendable dictionary captured by loader closures. The final candidate uses
an explicit JSON enum import, the SPI import and a captured optional model-type
string. It also removes an accidental duplicate Foundation import.

Standalone attempt 3 compiled successfully (238.01 seconds wall time;
237.24 seconds reported by Swift). Five invalid-option combinations are refused
before model loading or report creation; the current top-level Swift error
mechanism exits those probes with signal 5. These are deliberate argument-error
controls, not inference crashes. Provider `--help` passes. Source-alias and
artifact-copy wrapper failures are retained with their explicit corrections.

Root verified 257 payloads across semantic, cancellation and three release
attempts, eight runtime files, resolved compiler paths and the final 65 owned
source hashes. The integrated delta contains 15 source paths: the 13-path grant
patch followed by the eight-path standalone patch, with six overlapping files.
Native engine `aafe2069bcdeadef9250530eb511c598649c0355` is unchanged.

## Artifacts, evidence and remaining gates

- Provider CLI SHA-256: `a81fd9f9ff01fb84f3c236ceaba5fed4fca730b261be1f332b87c38e69cd3cfd`.
- Benchmark SHA-256: `601bce0923cfb2e12410073fe193a08a9c73830b5afd74d7f72e2facb49be21c`.
- Metal library SHA-256: `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0`.

The [manifest](evidence/production-grant-harness-2026-09-05/manifest.json) and
[archive](evidence/production-grant-harness-2026-09-05/payloads.tar.gz) retain
252 payloads, including source manifests/patches, raw execution logs,
negative controls and root checks. Runtime binary hashes are retained; binaries
are stored in the separate validation artifact package.
Manifest SHA-256: `7540b456b56532343530d780374e48b8b2b2b54b2f1f3784a5d19643eec9a9c9`.
Archive SHA-256: `75ddfd771e691ce22f1eb5373932dd2114d1bce41691030b4535fbe63d1647c5`.

Exact-model normal-MTP output, actual SSD reuse, B1/B2/B4 performance, real
capacity/co-residency, HTTP tools/vision, connected routing and signed persistent
restart remain separate release gates. No speedup, default promotion or 0.9.0
completion follows from these build results.

Related: [benchmark procedure](../developer/test.md#prefix-cache-benchmark-validation),
[build procedure](../developer/build.md#resident-prefix-benchmark-executable),
[production grants](2026-09-05-segmented-production-grant.md).
