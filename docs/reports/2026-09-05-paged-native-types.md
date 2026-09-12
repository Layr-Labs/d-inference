# Native KV types and explicit Qwen paging

> Last updated: 2026-09-05 · commit `544cfa5ee`

Explicit paged construction now measures the loaded target's actual K/V types
before selecting storage. Qwen dense and MoE targets can use segmented paged KV
when that measured table is present. Default `auto` remains contiguous, and
complete Qwen SSD checkpoint restore remains contiguous-only.

Native commit `02acd0e52d3dc88257dca5f3db4257aeda4db48e` contains the 22 tested paths.
The native semantic gate passed 109 actual cases; the final provider gate passed
47 functions. These are bounded mechanics and tiny-model tests. Full-size target
probes, paged SSD restore, fleet capacity, throughput and default promotion are
separate gates.

The [evidence manifest](evidence/paged-native-types-2026-09-05/manifest-api.json)
retains source/commit proofs, every build/test log, initial failures and release
provenance. The release artifact contains binary
`216adc9b7f0131c7143f1317a5500a5ed2d58c1bc748b6e3b93aa4c6e8dca8c5`
and pinned metallib `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0`.
Its source manifest covers 1,108 selected source and manifest/lock files;
other dependencies are identified by their pinned revisions. The pinned MLX
worktree is clean at `6b0505cc790f512ae49d740b21e13f80802946bd`.

## Implementation

The load-time probe runs two prefill tokens and one decode token through the
normal model adapter and fresh cache entry point. It observes K/V after the
model's projections and positional transforms, checks types and shapes before
evaluating the graph, and releases request-local recurrent state and rows.
Returned observations contain metadata only. Asymmetric K/V, changes between
phases, missing updates and invalid shared owners refuse construction.

An explicit per-layer type table separates physical groups by native dtype,
geometry and full/window ownership. BF16, FP16 and FP32 remain native; no cast
is introduced to make a model eligible. A nonempty scalar dtype override must
match every observed layer. Qwen's engine capability additionally requires
segmented storage and this explicit table; the fixed-pool reference does not
satisfy that gate. Production preparation uses a 64 MiB segment target while
retaining the existing provider physical-cap policy.

The slot's full-attention marginal byte rate now uses the constructed pool's
table, with shared and window rows excluded as in existing sizing. A regression
compares mixed widths directly with native AdmissionV2. This does not complete
shared paged accounting: bridge per-request GlobalKVCacheBudget reservations
still apply only to contiguous requests. Cross-slot physical floors and fixed
window/recurrent/MTP commitments need their own measured capacity gate.

The candidate benchmark adds `--native-kv-probe-only`. It requires cache-off,
MTP-off and one request, binds the normal immutable metallib, brackets loading
with verified weight hashes and computes the artifact's real prompt identity.
It constructs no serving engine or SSD store. Normal paged serving comparisons
must separately preserve the model's applicable MTP mode.

## Validation

| Gate | Cases | Result |
|---|---:|---|
| Real tiny dense/MoE Qwen paged MTP rollback/cancellation vs contiguous | 2 XCTest | 5.283 s, passed |
| Loaded type probe and mixed page layout | 5 Swift | 0.619 s, passed |
| Physical admission and native allocation release before floor refund | 12 Swift cases | 1.002 s, passed in a standalone process |
| Qwen capability/configuration and MoE complete-checkpoint reference | 13 XCTest | 1.263 s, passed |
| Segment transfers, partition kernels and grant lifecycle | 23 Swift cases | 5.612 s, passed |
| First-token deadline and resident-prefix contracts | 28 XCTest + 26 Swift | 3.825 s + 2.625 s, passed |
| Provider native construction, dtype override, marginal rate, bridge and backend policy | 47 Swift | 2.142 s, passed |

The native total is 43 XCTest plus 66 Swift parameter cases (52 Swift functions),
with no skips. All 440 captured native source/test hashes matched after testing.
Native semantic compilation passed in 88.16 s; the final provider build passed
in 119.98 s. The provider source snapshot includes the final marginal-rate fix.
The candidate release compiled in 247.37 s and its source hashes were checked
again before archiving executable and resources.

Retained first attempts include a provider test compile failure from an optional
row lacking an unwrap, and six runtime issues caused by ambiguous old release
and current debug Metal resource bundles. The fixture was corrected. The old
scratch bundle was hashed and moved outside lookup roots; unchanged executable
source then passed 46 provider functions. The final added rate case brings that
total to 47. No numerical oracle was weakened. A test-only engine-queue barrier
establishes final gauge publication before Qwen terminal assertions.

## Remaining release gates

The original physical-cap policy and `auto` selection are unchanged. The
36/64/128 GiB envelopes, co-resident load/lifecycle, full-size B1/B2/B4 output and
memory comparisons, supported vision/tool serving and page-native complete SSD
transport remain required before 0.9.0 promotion. A passing target-type probe
cannot substitute for those tests or for actual cache hit/read evidence.
