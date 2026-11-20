# Originating distributed request deadlines

This private overlay removes the distributed timeout restart at engine queue admission and at pipe reservation. It changes only the opt-in distributed path. No main-repository files were edited, and no model, network or remote worker was run for this task.

`DistributedRequestDeadlineContext` carries a provider-local `ContinuousClock` generation deadline and a separate optional first-token deadline. Ordinary distributed submit establishes its profile ceiling before entering the engine queue. The provider bridge uses its own frame-receipt `RequestProfileBuilder.continuousAnchor`, or bridge entry when no receipt profile exists. Its optional explicit distributed context can only shorten that ceiling. The coordinator `firstContentBudgetMs` continues to constrain first content; it is not reinterpreted as a whole-generation budget. No OpenRouter timestamp or upstream wall clock is trusted or added.

The additive `DistributedDeadlineExecutionOwner` capability passes this context through reserve. `DistributedPipeExecutionOwner` implements it; existing injected owners keep their original API and engine-side deadline checks. Those compatibility owners do not gain interruption of synchronous reserve waits. Direct calls to the old PipeOwner reserve API still establish a profile allowance at that API's entry.

At pipe reservation the owner samples `DispatchTime` before sampling `ContinuousClock`, derives signed remaining duration, floors to complete nanoseconds, and takes the earliest generation ceiling from the origin, profile and the two local worker lifetimes. Expired or unrepresentable allowances fail before reservation. This also fixes otherwise valid reservations failing solely because a full fresh profile allowance extends past an already loaded worker's lifetime.

First-token time bounds only the synchronous admission wait and the engine's pre-first-token phase. The pair's admission wait is the minimum of that limit, the generation ceiling and its existing five-second admission cap. The wire generation deadline is not shortened to TTFT. Once a token is committed, the existing event loop continues under the original generation limit. The engine's first-token/whole-generation event checks and actual retirement logic are unchanged.

A partial admission failure still quarantines, cancels and waits for actual acknowledgement/process fencing and resource release before reserve throws. An admission deadline initiates cleanup; it is not a promise that cleanup returns at that instant. Cleanup may outlast the request budget, and must never manufacture retirement to meet a timeout.

## Scope and clock boundary

Both deadlines in the context and the pair's advertised lifetime are local values. The context is not a cross-host DTO. The remote-owner adapter must sample remaining generation and first-token durations at send time, charge its local queue delay, clamp them to its own profile/lifetime, and derive new local deadlines once. It must not forward one Mac's `ContinuousClock.Instant` or native uptime to another. Heartbeats and later commands cannot replenish a deadline. Without bounded transit or synchronized clocks, a transported duration cannot establish an identical remote wall-time deadline; the originating provider remains responsible for acceptance/cancellation and independently observed fencing. Future sleep/clock-domain differences also do not transfer that originating responsibility to the child.

No protocol framing, peer identity, token, model, arithmetic, resource or remote authentication format changes are included. The pure remote-owner state remains a separate package. Its next endpoint abstraction must preserve `localLifetimeDeadlineUptimeNanoseconds` and the distinct admission deadline when replacing the current two-local-child pair.

## Files and promotion

`runtime.patch` contains seven replacements and two additions: the Foundation context plus one ProviderCore test file. The proposed paths preserve main-repository layout. Root should verify `origin-pins.json`, apply the patch to its current main tree, and run the full ProviderCore tests. Root retains integration ownership.

Runtime replacements are DistributedCBv2Engine, DistributedResidentExecution, DistributedPipeExecutionOwner, EngineV2Bridge+Submission, the one-line RequestProfileBuilder anchor comment, ClusterWorkerPair and ClusterWorkerRequest. The old distributed event handler and all existing provider/process tests are unchanged. Source preservation checks pin the legacy retirement/cleanup paths and existing protocol source.

## Validation

- `bash Tests/run.sh`: PASS, Swift 6 warnings-as-errors, 13 direct checks of the actual Foundation context/conversion source. Includes elapsed preparation/queue budget, independent TTFT, origin/profile/lifetime bounds, exact expiry, exhausted lifetime, overflow and fractional-nanosecond refusal/flooring.
- `bash Tests/run-pipes.sh`: PASS, Swift 6 warnings-as-errors. Compiles the actual protocol, process pair/request, provider owner contract and PipeOwner against test-only MLX value stand-ins. Four real local model-free children verify lifetime clamping, non-destructive expired-origin refusal, wire generation distinct from admission limit, and slow admission timeout followed by actual child fences before throwing. There is no JACCL/model/network execution.
- Nine proposed Swift files passed syntax parsing. The complete ProviderCore engine/bridge target has not been typechecked or executed here.
- Six new ProviderCore tests are staged, not executed here. They exercise the actual engine queue with a bounded two-thread gate, origin and reserve elapsed time, pre-reserve expiry, profile clamp, TTFT ending after the first token, and first-token expiry during unprojected reserve. Existing test support is reused unchanged. Root should run them with the unchanged existing distributed deadline/engine suites after integration.

The copied test protocol/process helpers are source-pinned. Only the test child gains three checks: a maximum wire deadline, a minimum remaining generation allowance, and a slow-admission behavior. No frozen previous overlay was edited.
