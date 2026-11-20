# Serial generation driver source

The overlay contains 11 new Swift files and four additive changes against the frozen resident-JACCL workspace. `integration.json` maps each file and its original hash; `runtime.patch` applies to that workspace's inference directory. The earlier contract snapshot remains unchanged. No `Options`, `Main`, provider, loader, package dependency or build-directory changes are included.

```swift
runQwenLayerStageGenerationRequest(
    loaded: LoadedQwenLayerStage,
    plan: QwenLayerStagePlan,
    agreement: QwenLayerStageGenerationAgreement,
    collective: Collective,
    onCommittedToken: (Int) throws -> Bool,
    check: () throws -> Void
) throws -> QwenLayerStageGenerationResult
```

The caller supplies one exclusively owned resident stage and runs this synchronous function on its request executor. Rank 0 uses the actual prompt and then the agreed selected tokens; rank 1 receives residuals and performs the existing stage forward and native finite argmax. Only rank 0 invokes `onCommittedToken`. Its `false` response causes clean EOS/length/client-stop agreement; a thrown error or failed `check` causes failed local retirement. The normal return contains CPU identities, selected token IDs, the common history digest and frontiers after both request-state retirement acknowledgements. The model remains the caller's resident property.

Before request-state construction, the driver binds the actual loaded source/plan/rank, applies the existing 16 MiB `CollectivePointToPointShape` limit to the largest admitted residual, and exchanges a separate generation readiness digest. Each residual is shape/dtype/source/token/payload checked. The consumer ACK follows its native commit; the scalar ACK precedes owner publication; both decision ACKs precede another forward. The existing Session `perform`, `decode`, input validation and owned-state arithmetic remain unchanged. No prefill lookahead, speculative tokens or MTP are introduced.

The profile is configurable adapter metadata. It is not permission to allocate a model or request state. The 8192/512/128 example has 16 prefill frames, 127 decode frames, capacity 8320 and last committed frontier 8319. The owner must admit that capacity and keep live resource/deadline checks active; the one-output benchmark admission is insufficient. It must validate both actual build identities, reserve both peers under one membership/request identity, and prevent overlapping use of either loaded stage.

On error this driver retires local state and throws. It does not send a cancellation into an arbitrary in-flight Collective ordering or claim the peer retired. The lease owner must deliver authenticated out-of-band cancellation and obtain retirement or fence both peers before `waitUntilRetired`/resource release succeeds. Existing alarms and remote process-group supervision remain the fallback for blocked native IO. A successful control send, EOF or elapsed timeout is not a retirement ACK.

Validation completed here: standalone Swift 6 warnings-as-errors contract compile and 11 accepted/25 rejected CPU checks; a separate 20-source compile and five two-control packet/history/stop/retirement cases; final 15-runtime-file source parse. Compiler/test stderr was empty. Receipts are included. The two-control fixture executes real pure codecs/controls, not the MLX driver or a socket simulation. Native driver typechecking, native numerical comparison, physical transport, performance and external TTFT remain untested.

Next integration is the provider's private `DistributedResidentRequestLease`: call this driver from its executor, return promptly from `start`, forward rank-0 committed tokens, and implement cancellation/fencing plus exactly-once reservation release. Keep normal callback `false` separate from abnormal `cancel()`. Root owns the native build and model run. The separately developed payload-cache fix touches different files; include it only after root's validation, without replacing the frozen source identity silently.
