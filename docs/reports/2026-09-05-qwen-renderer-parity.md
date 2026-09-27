# Qwen prompt rendering and shared token parity

> Last updated: 2026-09-05 · commit `d2ea8dfe4`

The coordinator and provider now agree on all 98 common request/token vectors
for seven pinned artifacts, including all five release models. The separately
preserved original four-artifact corpus also passes all 56 comparisons and keeps
its prior token arrays unchanged. This establishes prompt identity and rendering;
it does not establish paged attention, cache-hit inference or rollout readiness.

The [root evidence manifest](evidence/qwen-renderer-parity-2026-09-05/manifest-root.json)
and [provider evidence manifest](evidence/qwen-renderer-parity-2026-09-05/manifest-api.json)
identify exact sources, artifact digests, original failures and final logs.

## Compatibility changes

Swift Jinja 2.3.5 omitted neighboring loop items. Qwen templates use those items
to combine consecutive tool results into one user turn, so the provider emitted
incorrect grouping. The provider now pins 2.3.6 at
`0b67ecb79139f6addef8699eff3622808aa6c7dc`. The upstream executable delta is the
neighbor fix and a small expression-parser correction; later dependency versions
were not needed. All other resolved dependency revisions remain unchanged.

The sidecar's bounded `tojson` filter matches Swift's recursive key ordering,
ASCII/slash escaping, indentation and floating-point spelling. It serializes
values directly instead of first building a second JSON tree; output and key
sorting scratch share a 16 MiB bound. Ordinary template map iteration retains
its existing order. Tests retain 104 formatting and 530 edge oracle rows,
including 512 finite floating-point bit patterns. Enabling serde_json's existing
`float_roundtrip` feature fixes decimal parsing: the previous parser missed
136 of those 512 exact bit patterns, including ordinary fractional values.

Native prerequisite `c0c63e251a4d0fad9f1f8b04f4cbb45d4a0dd760` converts actual NSNumber booleans to native
Bool before Jinja sees them. Numeric zero and one remain numbers. The 66-row
before/after probe changes only the true, false and nested-boolean rendered
outputs; other rendered values and errors remain unchanged. Six parser and ten
existing server-translation tests passed in 0.001 s.

The planner rejects known unsupported representations before normalization or
artifact loading: canonically equivalent duplicate object keys, unsigned
integers beyond Int64, negative zero, and floating values at or above 1e16 in
magnitude. JSON-encoded tool arguments receive the same checks before null
sanitation, and valid nonobject JSON or object/array-looking parse refusals stay
cold. Ordinary non-JSON text stays opaque. This prevents incorrect token plans
without changing ordinary provider request handling or coercing values.

Normalization remains `darkbloom-request-normalization-v3`; renderer identity
becomes `swift-jinja-request-date-compatible-v3`. All prompt-contract IDs change,
so old ready receipts, preloads and exact artifact allowlists cannot be carried
forward as if compatible. Exact model templates are unchanged.

## Corpus and checks

The common corpus has 14 cases applied to every artifact: GPT-OSS 20B, Qwen 3.6
35B, Qwen 3.5 35B, Qwen 3.8 27B, the exact Gemma 4 26B fleet model, and two
additional Gemma variants. There are seven positive readiness checks and six
unique contracts. Common histories include an initial user turn and a reasoning
mode accepted by every family. Original GPT/Gemma histories and family-specific
argument/effort regressions remain tested separately; no model-specific skip
framework was introduced.

Provider build 7 passed 26 XCTest cases and 61 Swift Testing functions across ten
suites in 18.183 s, including actual immutable tokenizer/template comparisons
for all 98 cases. The separate original 56-case replay passed in 12.323 s.
Neither final run skipped a test. Earlier filter setup and accidental optional
live-test selection failures are retained; their skipped result is not the final
gate. The initial Qwen comparison exposed 12 divergent token arrays and 21 total
issues under Jinja 2.3.5; those failures are also retained.

Final Rust tests passed all 106 tests, with strict clippy clean. The new depth
regression proves valid deeply nested argument JSON cannot bypass eligibility
when serde refuses to parse it. Go prompt-contract and load-proof inventory
packages passed in 2.459 s and 0.511 s with the seven-artifact inventory.
Final generator output matches the provider-tested vectors byte-for-byte: common
98 SHA-256 `7bda5110dac22a0ab24d0b28a6502935de70d2571037a58dd77f3cad17cc0430`,
original 56 `6174b27c1fdf9a82f84b31d8d0e34394996884332c5a60d585aac26261349bbb`.
The original 56 token arrays are byte-for-byte unchanged from `8b8935fb4` despite
the new contract identity.

## Coordinator load and memory

The release sidecar passed the existing Go-supervised 25 requests/s, 15 s,
1,024 MiB RSS gate with all six contracts loaded. The cold burst produced 96/96
exact plans with six loads and 90 singleflight waiters. Sustained traffic produced
375/375 exact plans at 24.99845 requests/s, covered every vector, and reached
2 ms maximum scheduling lag. There were no timeouts, errors, cold reloads or
process restarts. Cold peak RSS was 1,000,357,888 bytes (954.02 MiB); sustained
peak was 914,243,584 bytes (871.89 MiB), with 4.67 MiB growth after preload.

The [load-proof manifest](evidence/qwen-renderer-parity-2026-09-05/manifest-loadproof.json)
records the exact release binary, source snapshots, invocation and results.
The local CPU/GPU build lanes were idle during measurement. This is one local
load proof, not a fleet latency result. Cold peak leaves about 70 MiB of RSS
headroom; it does not establish capacity for additional arbitrary contracts.

These builds contain concurrently developed native memory accounting. Full
source and runtime artifact hashes identify the tested state; they are not a
claim of a clean renderer-only build. Actual five-model paged execution, SSD
transfer performance and production-key process restart are separate gates.
