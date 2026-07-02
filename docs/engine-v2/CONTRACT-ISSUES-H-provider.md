# CONTRACT ISSUES — WS-H (provider bridge)

Places where the frozen `CBv2Contracts.swift` was insufficient for the
provider bridge, and the closest conforming shape chosen. None block
integration; all are resolvable with small additive contract changes on the
integration branch.

## 1. `CBv2Engine` is not `Sendable` — RESOLVED

The provider consumes the engine from an actor (`EngineV2Bridge`) and from
`Task`s spawned per request; `submit`/`cancel`/`capacity`/`shutdown` are by
design the engine's cross-actor entry points. The contract originally
declared `CBv2Engine: AnyObject` without `Sendable`, so any capture across
a concurrency boundary tripped Swift 6 strict checking.

**Resolution:** the contract now declares
`public protocol CBv2Engine: AnyObject, Sendable` (engine tip `8662159`).
The interim `@unchecked Sendable` wrapper (`EngineV2EngineBox`) has been
removed; the bridge holds and calls the engine directly.

## 2. No representation for "chosen-token logprob only"

OpenAI's `logprobs: true` with `top_logprobs` omitted/0 means "return the
sampled token's logprob, no alternatives". `CBv2SamplingParams.topLogprobs`
overloads 0 as "no logprobs at all", so that request shape is
unrepresentable.

**Chosen shape:** `EngineV2Translation.topLogprobs` maps
`logprobs == true` to `min(20, max(1, top_logprobs ?? 0))` — the chosen
token's logprob is still captured at the cost of one extra alternative.
**Suggested contract fix:** split into `reportLogprobs: Bool` +
`topLogprobs: Int`.

## 3. No engine-loop progress / watchdog surface for `step_wedge` — RESOLVED

The spec asks for an `engine_v2.step_wedge` signal "from the v2 watchdog",
but `CBv2Engine` originally exposed no step counter (legacy:
`EngineCore.stepsExecuted`) and no watchdog callback;
`CBv2CapacitySnapshot` carried only request/byte counts.

**Resolution:** `CBv2CapacitySnapshot.stepsExecuted` (engine tip `8662159`)
is a monotonic engine step count published every step. The bridge samples
it into the existing `WedgeMonitor` on the heartbeat cadence
(`EngineV2Bridge+Capacity.backendSlotCapacity`), replacing the interim
event-count proxy — a stalled engine stops incrementing it, which is the
exact flatline term `wedgeSuspected` requires. Admits and first tokens are
still recorded from bridge-observable signals; wedge transitions emit
`engine_health` telemetry with `operation=step_wedge`,
`backend=engine_v2`, unchanged.

## 4. `CBv2CapacitySnapshot` lacks worst-case + queued token views

The heartbeat protocol reports `max_tokens_potential`
(Σ prompt+maxTokens across running requests) and `queued_token_budget`
(token budget of the waiting queue). The snapshot only carries
`waitingRequests` as a count.

**Chosen shape:** the bridge computes `max_tokens_potential` from its own
per-request bookkeeping and reports `queued_token_budget = 0`
(`num_waiting` still carries the queue depth). Budget used/max are derived
truthfully from `kvBytesInUse / kvBytesPerToken` per the spec.
**Suggested contract fix:** add `waitingTokens` and `maxTokensPotential` to
the snapshot.

## 5. Logprobs have no path to the provider's stream surface — RESOLVED

`CBv2Event.delta` carries `[CBv2TokenLogprob]?`, but the provider's
`GenerationEvent` (`.chunk`/`.info`/`.error`) — the shape all downstream
SSE/billing/attestation plumbing consumes — has no logprobs channel, and
extending it would break exhaustive switches across the legacy path
(violating "flag off ⇒ byte-identical"). The upstream
`MLXServerGenerationEvent`/`OpenAIChatCompletionChunk` types likewise have
no logprobs field.

**Resolution:** logprobs travel out-of-band (`EngineV2Logprobs.swift`).
The bridge pump converts each delta's entries to the OpenAI streaming
shape (`EngineV2Translation.sseTokenLogprobs`) and appends them to a
per-request `EngineV2LogprobsChannel`; the coordinator inference handler
drains the channel per SSE frame and splices
`choices[0].logprobs = {"content": [...]}` into the next content-bearing
chunk (`ProviderLoop.injectLogprobs`) before encryption. NOTE: the legacy
engine never emitted logprobs, so this is the OpenAI-standard shape, not a
legacy match; the standalone `--local` path (frames served inside the
upstream router, no provider seam) still does not emit logprobs.

## 6. Admission error granularity

Legacy admission distinguishes queue-full (429) from budget-exhausted (503)
via distinct message strings. `CBv2KVError` has only
`capacityExhausted(needed:available:)` (plus `backendIneligible`), and its
units (tokens vs bytes) are unspecified.

**Chosen shape:** `capacityExhausted` maps to the canonical
`token_budget_exhausted: request requires N tokens but only M available`
string (→ `.tokenBudgetExhausted` → 503, retryable), treating the values as
token counts. `backendIneligible` maps to a non-capacity message
(→ `.generationFailed`, non-retryable) since retrying a statically
ineligible backend is futile. **Suggested contract fix:** add a
`queueFull` case (or a reason enum) and document the units of
`capacityExhausted`.
