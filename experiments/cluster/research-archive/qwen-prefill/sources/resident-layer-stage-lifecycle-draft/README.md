# Resident layer-stage scoped lifecycle draft

2026-09-14. Out-of-tree source proposal. Swift fixtures have not been compiled or
executed by this author. No native model, GPU, SSH, provider or repository change.

`QwenLayerStageResidentLifecycle.swift` is the only proposed runtime addition.
It is a Foundation-only scoped callback gate with an explicit 1...16 request
cohort bound. `QwenLayerStageResidentFakeOwner.swift`,
`QwenLayerStageResidentLifecycleCheck.swift` and `QwenLayerStageResidentOverlapCheck.swift`
are standalone test sources, never production model/loading abstractions. Root owns
their compiler execution.

## API and state

- Construct with `maximumRequests`, then call `withRequest(identity:) { ... }`.
  Its private lease succeeds only after the body returns. A request UUID and wire
  epoch may appear only once. Repeated A/B/A history fingerprints are permitted;
  native admission still owns construction and validation of actual fingerprints.
- A thrown body, invalid admission, reentry or overlapping call poisons future
  request admission. A caught nested error still invalidates the outer success.
  The gate never silently queues overlapping work or attempts request recovery.
- After the request body has unwound, `withModelRelease { ... }` may run once even
  for a poisoned cohort. It cannot run while a request is active. A failed or
  invalidated release is terminal and cannot be retried through this gate.
- The snapshot records completed **CPU scopes** and completed **release callback**
  separately from failure. Cleanup does not turn a failed cohort into a pass.
  A later invalid operation does not erase an earlier completed release fact.

There is no external completion method, Boolean retirement certificate or public
lease constructor. The generic body return is deliberately not a type-level proof
of CPU ownership. Only the real private owner may use it; that owner's public API
must return a closed CPU result, never an arbitrary caller callback or Loaded stage.
The gate neither checks source identity nor claims native state was retired.

## Reuse the existing implementation

`WorkerSession` already demonstrates loading once and running requests inside
autorelease scopes. `WorkerSequence` validates its older worker command protocol,
not stage request lifetimes; reuse the pattern without another command decoder.
The existing stage request/context/wire lifecycles remain one-shot.

The real new owner should privately create and retain one verified Loaded stage
and the group. For each request it rebuilds the existing CPU admission/agreement
with fresh UUID/epoch, calls `runQwenLongPrefillRankRequest` unchanged inside an
autorelease scope, performs existing late error checks, and returns only CPU data.
The existing request function proves native frame/ACK/token/post-stop completion,
closes state and clears final logits before returning. Its next fresh readiness
exchange is the peer barrier. An error ends the cohort and the parent fences both
processes; this gate does not repair failed transport or replace cleanup reporting.

At cohort end the real release callback drops the private Loaded capability,
synchronizes, checks the weak model reference and clears the allocator cache using
the existing outer cleanup pattern. Preserve the original load receipt as historical
evidence; do not claim model release while weights remain resident. A failed request
cleanup remains failed even if the model can subsequently be released. Keep existing
one-shot modes and their outer report schemas unchanged. Initial observer arguments
are nil; no shared one-shot phase/owner captures.

No provider hook or new fusion/evaluation boundary is required. The separate
`PROVIDER_DEFERRAL.md` supersedes the first plan's proposed mandatory physical seal
for this initial ownership qualification without modifying the frozen old plan.

## Prospective validation

The check contains 21 named cases. Its fake owner creates the model internally,
retains it privately, constructs fresh request objects, returns a fixed CPU result,
and checks weak lifetime after each scope and final release. Negative cases include
request/model escape injected only through the fake ledger. No fake tensor math,
fusion behavior, network transport, numerical parity or actual model reuse is
qualified by these fixtures. One bounded overlap case runs both request and release
contenders while a first body is semaphore-blocked; each variant joins its two
pthread handles after bounded completion waits. A success report records all four
actual joins. This is a focused overlap fixture, not a threaded stress qualification;
the private production owner is intended for serial callers. None has run yet here.

Root can compile all four Swift files together using `swiftc -parse-as-library`,
then retain the emitted JSON test result separately. Source checks in this package
only validate file/dependency pins and the intended API surface; they are not a Swift
compiler or execution substitute. After root's pure checks, the next step is the real
private owner around the existing loader/request function, followed by the existing
tiny same-model parity path with A/B/A and injected cancellation before real models.
