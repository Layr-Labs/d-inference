# SSD eviction can preserve bytes while losing cache discovery

> Last updated: 2026-09-25

## Status and scope

Initial reproduction plus the implemented active-store retirement repair below.
No wire format or model changes. Original baseline:
`b6f9574ed40a5e1f8b8fb288224ea3de88d1be98`.
Model weights, quantization, SDK pins and inference arithmetic are unchanged.

## Commit/retirement follow-up — deterministic native qualification

Independent source review identified a rename-to-index race in the active-owner
retirement repair: whole-root eviction could unlink a newly renamed checkpoint
before its writer inserted the RAM index, without changing the epoch. The late
insert could then advertise a missing file. This is an accounting/publication
defect; native authentication still rejects absent or invalid payload bytes.

The follow-up uses the existing process-wide per-file coordinator for both
complete-checkpoint and attention write-behind commits. The writer owns that
file through rename (or duplicate authentication) and index insertion, then
releases before its own maintenance. Retirement only tries the file lease and
skips busy entries; it never waits while holding epoch/disk-budget locks.
Startup scan insertion uses the same nonblocking boundary. Final complete
donation/publication also requires the path to be a regular no-follow file.
Unrelated eviction, post-commit self-eviction, destructive binding/corruption
fences, queue/memory bounds, authentication and model numerics are retained.

New deterministic tests pause the actual encrypted writer after rename and
before insertion, run whole-root eviction with newer inactive-root bytes, run
reconciliation, then resume and authenticate the survivor. They also cover
authenticated duplicates, attention write-behind, unrelated survivors,
post-commit budget eviction, queued-writer cancellation and lease cleanup.

The first fresh build caught a test-only timestamp API argument-label typo;
the corrected fixture compiled successfully. This setup failure is retained
and is not the intended defect reproduction.

At corrected source tree `a81d6f5b3ea0237e386b17d958de669bcde657fe`, the actual-writer
CPU suite passed four functions (five cases including fresh/duplicate). A separate
compiled control replaced only the retirement helper with the original PR20
helper. The unchanged tests then failed at actual fresh/duplicate file loss and
attention-file retirement, while self-eviction and queued-close controls passed.
Restoring the exact corrected tree and rebuilding passed 27 tests in six suites,
with zero failures/skips: the writer suite, file coordination/path aliases,
owned retirement, epoch persistence and CPU survivor restoration. These runs
overlap; do not add them as independent coverage.

That first restored test executable SHA-256 is
`3d1cbddd86e5ecef9509da4a8bebc28ebcd35134aee6a8ec35b768ed467ba97a`;
fresh source-matched metallib SHA-256 is
`38ceb8a1113b373ccaa89355d895fc8ded3bafc81076dc4ffdb426e2eee03a93`.
Effective toolchain was installed Apple Swift 6.4, explicitly not a claim of
Swift 6.3 qualification. No model, live endpoint or production key was used.

A fresh build at tree `2c9654781fc3a5c692f8cc09bebc26e669b7a1ff` added
`SSDCheckpointCPUAcceptanceTests` without changing production code or existing
oracles. The complete selected run passed 32 test functions in seven suites,
with 63 parameterized-or-single invocations, zero failures and zero skips.
The 33 added cases exercise 12 lifecycle scenarios, four duplicate geometries,
ten invalid identity/authentication/corruption variants, six shared-ownership
scenarios and whole-root telemetry. CPU selection is asserted before and after
each wrapper. Before/after source, executable and resource hashes match.

Current test executable SHA-256:
`188476c58f7920227dcd7db307e18a87bab0fae8ac498540a19da2e4471a1d5c`.
The metallib hash above is unchanged. Run the selection documented in
[the test guide](../developer/test.md); counts overlap prior runs and must not
be added as unique coverage.

A separate local probe linked 2,194 current task-built library objects, excluding
the CLI entry point, to the unchanged public-key CPU fixture driver. Four distinct
processes passed: write two checkpoints and retire the older, restart and restore
exact KV/conv/SSM state, reject another tenant without payload reads, then restart
and restore again. The durable epoch remained stable and ownership drained.
Linker inputs/flags and object/source hashes were verified before and after link.
Probe executable SHA-256:
`6c6bc17e22705ad4d1fa5e47dd8cc5a17c6bec833016586b40cf23aa9d2a02f1`.
This is local fixture qualification, not a committed automatic process-test
target or release-signed Keychain persistence. The exact driver and receipts are
retained with the review evidence.

Independent final source/evidence review remains required before staging this
follow-up. These deterministic native checks are not new real-model benchmarks,
hosted OpenRouter certification, a balanced end-to-end latency measurement or a
44–48% fleet hit-rate result. Earlier large-model results below remain historical
with their recorded source-provenance limits; they are not relabelled as this
new candidate's full-model qualification.

## Reproduced sequence

1. A native encrypted store writes a checkpoint.
2. Its normal disk-budget maintenance evicts an older entry.
3. Destructive maintenance rotates the model-root cache epoch.
4. The write job's old epoch no longer matches, so it returns no donated
   positions and its READY announcement is suppressed.
5. The new file still exists and a fresh native stage successfully restores it.

The writer is in `SSDHybridCheckpointStore+Write.swift`; maintenance uses
`performIndexedDestructiveChange` in
`SSDHybridCheckpointStore+Maintenance.swift`.
The evidence sequencer separately rejects proof issued under the old capability.
At the coordinator, an epoch change removes **every holder for that provider
and model**, not just the evicted entry.

The added Go witness creates 64 prefix locations for each of two models,
changes one epoch and verifies exactly 64 affected-model locations disappear
while the other model's 64 remain. This is not evidence of 64 files deleted.

The added Swift witness uses the existing hybrid checkpoint fixture, an owned
temporary encrypted root and a controlled disk budget. It verifies both the
lost publication and a successful 512-token read of the surviving new file,
then drains the store and requires zero staged bytes. The CPU wrapper selects
tiny CPU tensors; no model or inference server is loaded.

The initial diagnostic commit asserted the failure. The implementation replaces
those expectations with preserved READY publication, unchanged epoch and actual
survivor restoration; corruption/external-change controls still require fencing.

## Existing evidence

The original CPU execution passed in 12.382 seconds, with unchanged binary and
inputs, a CPU-only marker and the survivor/restoration witness. Retained log
SHA-256:
`29c4e76a69a9c98aeea61c27abf6fb592a81953b6ee17f1bd4a395e6b7ad074f`.

A separate native Bonsai experiment connected real providers through an
encrypted mock coordinator with a controlled 0.75 GiB disk budget.
Eviction rotated the epoch and suppressed lookup/READY evidence; a forced repeat
restored 4,096 tokens from surviving bytes with equal output. This distinguishes
lost discovery from unreadable data; it is not a repaired-candidate benchmark.

Existing cache functionality also works under compatible conditions. One
matched cache-off/SSD repeat restored 4,096 tokens and reduced measured TTFT
from 17.202 seconds to 3.182 seconds; cold controls were 17.201/17.177 seconds.
This is a single matched pair demonstrating existing reuse, not a new speedup,
confidence interval or fleet hit-rate result.

## Implemented repair and preserved constraints

Known-entry retirement in active attention and complete-checkpoint stores now
uses one exact-path/no-follow helper under a verified durable binding barrier.
It does not reset the epoch or receipt sequence. Active whole-root TTL/capacity
maintenance delegates to that owner rather than invoking whole-generation
destruction. Unexpected missing/replaced entries still request destructive
reconciliation; corrupt reads and key/model/layout changes retain the old fences.
Inactive roots keep conservative generation-wide maintenance.

No revocation frame was added. Deleted-file hints can remain until an accepted
miss or existing bounded TTL; they are never accepted as native cache hits
without authenticated restoration. The coordinator's existing miss invalidates
all attempted boundaries for that provider, not merely one file.

Separate known-entry routine eviction/TTL retirement from changes that require
generation-wide invalidation. Preserve full invalidation for changed keys,
model/contract/layout/numerical identity, unsafe roots and untrusted destruction.
Do not bypass epoch checks or relabel old proofs with the new epoch.

Design hint revocation end to end before changing maintenance.
`coordinator/registry/cache_receipts_v2_lookup.go` removes the provider's
holders for every boundary in the current attempt on absent/corrupt misses;
it is **not** an existing single-file tombstone protocol.
Consider bounded stale hints, concurrent writes and readers, whole-root disk
budget ownership, and both checkpoint and attention-only stores together.

Required repair gates: known victim versus survivor/new file; another model;
TTL and capacity; external deletion, corruption, unsafe paths and key changes;
reader/writer races, cancellation, teardown and process restart; nonce,
sequence, connection, scope and replay rejection; unchanged native state/output
and bounded memory, I/O, latency and write endurance.

A conservative refusal to write under pressure trades new coverage for retained
coverage, but does not by itself solve unrelated TTL/global maintenance.

## Reproduce

From the coordinator directory:

```bash
go test ./registry -run TestDiagnosticCacheEpochFanout -count=1 -v
go test -race ./registry -run TestDiagnosticCacheEpochFanout -count=1
```

For the tiny native CPU witness, use the repository Swift test build and
source-bound MLX resources described in [test commands](../developer/test.md),
then select `SSDCheckpointPublicationCPUTests` with Swift Testing.
The ordinary wrapper additionally runs on the selected default MLX device.
Do not claim GPU model qualification from the CPU wrapper.

## Initial diagnostic review validation (before repair)

The focused Go epoch witness and race-instrumented repeat pass. The native CPU
witness was repeated: one test passed in 0.215 seconds (8.490 seconds including
runner startup), with no memory-guard intervention. Its two test sources match
the archived compiled inputs and the staged additions byte for byte; the relevant
provider cache tree and dependency pins are unchanged between that build's
baseline and the stamped commit. This was a source-equivalent existing-binary
rerun, not a fresh full build of this review branch.

Repeat binary SHA-256:
`04af027b8bbcb9f6bfc4c6657c05342c4a6a1e41da5deab62b130dfeb1332e9b`.
Repeat log SHA-256:
`46b0b89c5aa69d3e63d4eb7e3b82dc8a0cc6b466ed39487cd008bebd0cc14bb4`.
SwiftPM emitted existing dependency-identity, invalid-exclude and unused-package
warnings. No model or GPU inference was run during this repeat.

## Remaining qualification

The repaired native candidate passes 167 storage tests in 30 suites. A first
run had one missing test-resource error; exact source-matched paged-attention
resource staging resolved that runner issue without changing assertions.

The fresh optimized provider plus repaired coordinator passes the original
0.75 GiB pressure sequence: real eviction observed, unchanged epochs, accepted
READY/hit receipts and two exact 4,096-token restores with identical outputs.
All three cases pass (plus parent); wrapper 96.703 seconds. Result log SHA-256:
`2a2e9615bcff9da851dab322a407aefcddf35ca58fc6f52e40c26a4a415c7c7a`.
The regular cache-off/on API matrix subsequently passes all ten cases in each
arm (plus their parents). All nine non-cancelled authored response/reasoning/tool
results agree between OFF and SSD; cancellation is independently verified, not
compared as identical partial text. Tenant isolation, cross-provider routing,
tools, image input, cancellation/recovery and sidecar-unavailable fallback pass.
SSD log SHA-256: `71280e8266a388e58f6f2422fa145b7d84640aa0c8597329c00764ca20d9d590`.
OFF log SHA-256: `2efaa8c02ec99bf142ef2f8d4670caf5060a473bf6eea7ecd4537e672d21e0f4`.
The same-prompt repeat reports 17.669 s OFF and 3.248 s SSD, restoring 4,096
tokens. This demonstrates retained reuse, not a new general speedup: the arms
have different inter-request telemetry/donation dwell and are not balanced
performance-regression measurements.

A stronger pressure repeat leaves both real providers eligible after the first
donor. All three requests pass, follow the cache-aware route, retain the epoch
and exercise actual eviction. The final run restores 4,096 tokens twice;
wrapper 94.614 seconds, log SHA-256:
`f43aaf74d5e8ea76e495710dfc702be87bf8ed24e3b27e6b2131da16a18aea0e`.
Its preceding run exposed an overly specific test assumption: LRU timestamp ties
can leave either the 2,048- or 4,096-token file. The original baseline diagnostic
already allowed both. That failed assertion is retained; the corrected first
repeat must match an endpoint previously advertised by its selected provider,
and the stable repeat still requires 4,096 tokens. No runtime/tolerance change
was made in response to that fixture failure.

An additional 53-test/11-suite native run passes read coordination, duplicate
writers, recency, shared-process memory ownership and diffusion checkpoint
controls (some coverage overlaps the 167-test run). Native Bonsai two-active-row
and cancellation checks pass 14 cases; native Qwen4 default queued policy passes
21 cases with MTP off/on and exact shape-matched tokens. Qwen4 intentionally
remains one active native row; this is not experimental multirow qualification.
The separate Qwen4 cache-OFF/SSD-target/SSD-MTP test passes 12 cases with exact
raw-token equality and unchanged published model hashes.

Four distinct CPU processes also pass after real retirement: write two encrypted
checkpoints, evict the older file, restart and restore exact KV/conv/SSM, reject
the other tenant without payload reads, and restore again. The durable epoch
stays unchanged and ownership drains. This uses a public fixture key, not the
production Keychain. Result SHA-256:
`b3ca0501412edffcc5288eb6e89d733f69be6def912fdc80c12d2ed69521cc72`.

Native evidence log SHA-256:

- Additional storage: `5e0f4aea3275898da884841511427dd662621d13aecd2632071b1827ed8ceb30`.
- Bonsai concurrency: `19b6b3b1b94e4f226ba76285b8a57306d59cc067a1be7843dd33779e2b09b557`.
- Qwen4 concurrency: `15c6b54bc81e4b0a3b9f96ac0c303586ad01b9fc0dd7448bb67be0cf452b2f12`.
- Qwen4 cache/MTP: `d5b0e65cbb54ffe3636ada4ffcc8c7235479ed98bb3230beadd5f67d82d0d8cf`.

No fleet 44–48% attainment or hosted OpenRouter certification is claimed.
Fixture-key restart is not the release-signed persistent-Keychain gate. A
cohort-bound production metric is still needed to quantify the fleet effect.
