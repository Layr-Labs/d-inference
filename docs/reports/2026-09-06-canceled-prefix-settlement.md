# Native prefix lookup settlement after cancellation

> Last updated: 2026-09-06 · commit `384c321aa`

Partial-output cancellation now waits for the native bridge to finish recording
actual cache usage and resolve its lookup receipt before the provider sends its
terminal message. A deterministic real-engine regression reproduces the old
ordering failure in both SSD-hit and cold cases; the candidate passes all 15
selected filters, with 76 function executions covering 73 distinct identifiers.
The [HTTP5 failure](2026-09-06-connected-http5-cache-and-cancel.md) remains a
failed real-model result until a rebuilt provider passes a fresh strict HTTP run.

## Behavior and ownership

`EngineV2RequestUsageSignal` in
`provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge+PrefixCache.swift`
owns one terminal observation. `EngineV2Bridge+Events.swift` arms it before
starting the pump and completes it when the pump retires, after native usage has
invoked the lookup callback, or after stream teardown. Completion resumes each
waiter once, outside the signal lock.

Only the partial-output cancellation branch of
`provider-swift/Sources/ProviderCore/ProviderLoop+InferenceHandler.swift` calls
`settleCancelledStream` in `EngineV2Bridge+Lifecycle.swift`. The already-owned
bridge matches the request profile, cancels its currently mapped native request,
and awaits that observation. The handoff uses no polling, delay, or projected
cache-hit inference. Existing `cancelIfOwned` snapshots and pre-output refunds
retain their behavior. Billing is computed from delivered output before waiting,
so native decode tail work cannot increase the cancellation charge.

## Verified negative control and candidate

`ProviderCancelledPrefixCacheTests.actualRestoredCancellationSettlesBeforeTerminal`
uses a tiny synthetic recurrent model through the real paged `EngineV2`, encrypted
SSD store, sealed request, provider handler, and decrypted output recorder. A
normal donor must produce a visible token and complete before its 512-token
checkpoint is accepted. The test requires visible partial output before canceling
and holds native terminal usage to make the ordering deterministic.

| Gate | Instrumented baseline | Candidate |
|---|---|---|
| Donor output/completion and actual partial delivery | Pass | Pass |
| Actual native adoption | SSD snapshot hit, 512 tokens; cold miss, zero | Same |
| Provider terminal while native usage is held | Premature terminal in both cases | Waits |
| Lookup then provider completion, exactly once | Lookup missing in both cases | Pass |
| Terminal cache outcome/tier and saved-token fields | Missing in both cases | Pass |
| Delivered-token billing and resource cleanup | Pass | Pass |

The baseline has exactly 12 intended assertion failures: six ordering, receipt,
and terminal-cache failures in each argument case. It has no donor, first-content,
native-adoption, billing, or cleanup failure. The same handler test passes in the
candidate. `CancelledSettlementLifecycleTests` also covers canceled waiters,
normal native terminal, closed streams, shutdown, inactive/completed observations,
and duplicate observation completion.

All 15 candidate filters pass with nonzero test counts and no skips. Their raw
logs report 76 function executions; three verdict functions execute again under
the recovery filter, yielding **73 distinct identifiers**. Parameterized argument
cases are separate from that function count. Existing filters cover profile
cancellation, refund/accounting, event/error framing, lookup/Ready ownership,
shared grants, retirement, and wedge recovery. Exact identifiers, commands,
counts, and log hashes are in the evidence archive's
`review/exact-test-results.json`.

Earlier attempts remain preserved: a test-barrier compile failure, a stopped
source-path proof, and fixture precondition failures. The final fixture explicitly
sets `reasoning_parser: "none"` because its tag-free synthetic output otherwise
remains buffered by the default think parser. Production parser defaults,
capacity, output limit, timeout, and all donor/adoption assertions are unchanged.

## Source correspondence and limits

Both variants use provider base `5b93195c93efce01a4d455f8e2d0f04e68268096` and
the explicit native archive `5cb848dfdaae04118ecfa901f53fc21a4aa86a06`.
The baseline adds neutral test hooks and the same two handler fixture files;
the candidate adds the settlement handoff and lifecycle tests. The final candidate
files match the frozen source6 patch, compiled workspace, and proposed integration
bytes exactly. Its five production preimages match integration parent `384c321aa`.

Before/after checks verify 685 candidate provider files, 888 native files, 1,356
dependency files, and 27 Jinja files, with unchanged pins and actual compiler
source paths. Local package overlays select the pinned MLX source; the build uses
the reviewed build8 metallib. Native `e972340a` in the integration worktree adds
attention diagnostics, owner identity, and their tests relative to tested native
`5cb848d`; the exact delta is retained. **This validation does not claim a run
against native `e972340a`, a real-model HTTP pass, numerical parity, or a latency
improvement.**

## Frozen evidence

The [manifest](evidence/canceled-prefix-settlement-2026-09-06/manifest.json)
indexes 341 payloads in the
[archive](evidence/canceled-prefix-settlement-2026-09-06/payloads.tar.gz): all six
source revisions, all five validation attempts, final baseline/candidate raw
logs, build/source/pin proofs, exact test identifiers, and integration
correspondence. Original failed and superseded provisional verdicts remain
alongside their reviewed corrections. No executable, metallib, model weight,
cache key, or full dependency tree is included.

| Artifact | SHA-256 |
|---|---|
| Manifest | `12472f028fefacb846b587a70b7856f7c5f1b304c30cdc92e37913791b030ff3` |
| Archive | `6559546cfb74697eaa9196bbe904db027d41785b7ce0d242ed2bc40fc00400dd` |
| Final source6 manifest | `793a46d46adf075e1d6c2e1abc6898c7c6b945b7e5b69eba9024739fd91c9498` |
| Baseline real-handler log | `1aae7bdac68989861f004b24997c0c629d256d10b7cfbe79f57612ef3b4e9e30` |
| Candidate real-handler log | `1990a01a01f21f0f401e00bcbf846b6059933471030af615911fb6d23cb7d49f` |
