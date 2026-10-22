# Qualified 27B guard transfer audit

The narrow consolidation is valid to pursue, but retained evidence does not support a Gemma-sized speedup. Finish the actual Gemma full-EP cohort first. No runtime implementation, compiler, fixture, GPU, remote action, or source/cache materialization was performed for this audit.

`evidence.json` pins18 inspected sources. Thirteen actual resident files match the qualified3053-member source snapshot `e062d948`; the retained C256 native is `379b413d`. It also pins the four previously accepted serial/lookahead phase reports. This is a source and retained-scalar audit, not a repeat of their physical or numerical qualification.

The exact duplication is in `QwenResidentRequestResources.swift:79–82`: `ResourceEnvironment.require()` checks AC/low-power/thermal, obtains and discards a validated OS snapshot; `requireLive` immediately obtains another OS snapshot for the unchanged free-memory/allocator inequalities. `QwenDenseStageLoadResources.swift:9–67` uses Mach and sysctl directly, with no subprocess. Each read also constructs a UTC formatter/string. There is no `vm_stat` or `memory_pressure` process in this native hot path; the external physical supervisor is separate.

Unlike the old Gemma callback, the 27B resident gate already has a250ms cadence (`QwenResidentRuntime.swift:284–301`). Phase mode delegates to `QwenResidentPhaseResources.swift:81–95`, with the same cadence plus forced request-begin/retirement observations. All callback invocations still run cancellation/deadline and native-fault checks. Serial and lookahead share these exact closures; lookahead has no independent permissive guard.

The retained c35 recording worker calls `reserveRecording/startRecording`. Its `QwenLayerStageGenerationDriver.swift:73–76` invokes the resident callback and the diagnostic resource gate. `QwenGenerationDiagnosticResources.swift:51–67` has its own250ms cadence and the same environment-read/discard/reread duplication. Thus a logical callback can perform four OS reads when both gates are due. Ordinary serving and the explicit phase-memory path have only the base gate. The two independent cadences must remain independent in the first change.

The selected-tensor load gate (`QwenResidentLoading.swift:35–65`) already performs one OS observation per gate invocation. Its surrounding borrowed callbacks check native/control state only (`Runtime+Load.swift:59–60`). Those observations are not duplicate environment reads. Do not consolidate across tensor reads, conversions, stream synchronization, model execution, transport, or separate checks.

Retained request observations provide scale, not total guard attribution:

| Policy/rank | Live resource checks | Retained request samples | Admission sample median/max ms | Phase span s |
|---|---:|---:|---:|---:|
| serial/0 |112|47|0.559 /1.055|82.037|
| serial/1 |112|46|0.463 /0.604|82.065|
| lookahead/0 |111|46|0.504 /0.822|64.678|
| lookahead/1 |80|45|0.490 /0.582|64.705|

These sampled intervals include power/environment checks, both OS reads and the allocator diagnostic read, but exclude append and some surrounding checks; they are not every guard call. Their totals are21.8–25.5ms per rank. The inner OS timestamp bracket is only7–8µs median and ends before the UTC formatter argument is evaluated, so it must not be presented as total reader cost. No total-time upper bound or projected TPS follows.

The smallest reusable proposal is the already demonstrated environment-return seam: `QwenResidentResourceEnvironment.observe(...) -> QwenDenseStageLoadOSObservation`, with the C256 `additionalHostBytes` and `memoryPages` behavior preserved and optional metrics timing. Existing `require` remains a discard-result wrapper. RequestAllowance and DiagnosticResources each consume that freshly returned value locally instead of rereading OS; reapply `QwenDenseStageLoadPolicy.requireInitial` at the old second-read boundary to preserve the1s age/schema/floor checks. Keep all original arithmetic, short-circuit allocator-limit behavior, native/control exception precedence and6/4/2GiB terms. Capture memory pages from that same actual read for the existing memory sidecar. No snapshot field belongs on a runtime, owner, timer or async closure; the local value ends with that synchronous invocation. This halves reads within each due gate without joining separate callbacks. Sharing one read between resident and diagnostic gates would require a separate scoped callback change and is unnecessary initially.

Before a performance claim, add bounded optional count/wall-time instrumentation around existing logical checks, due resource gates, environment reads and unique OS reads, with no new observations/eval/sync. Count thrown paths via defer; retain inclusive-category semantics and separate native/wire intervals. Charge the actual fixed metrics/export allowance in existing Ready/reserve/load/request checks. A new benchmark schema must identify the changed observer overhead. Do not drop the existing cadence or change arithmetic/recording policy to improve a number.

Required controls for any later implementation: one actual reader invocation per due gate; same-value revalidation rejects stale/backwards/overlong samples; power/pressure/swap/free/allocator failures retain precedence; memory pages and snapshot share one observation; separate invocations cannot reuse a sample; thrown paths never update cadence/capacity; current driver/transport/model callsites and fault catches remain exact by inverse. Then short full-row/state correctness and a matched serial/lookahead27B cohort with identical prompt, chunk, capture mode, actual native/owner cleanup and resource floors. No27B implementation is staged now.
