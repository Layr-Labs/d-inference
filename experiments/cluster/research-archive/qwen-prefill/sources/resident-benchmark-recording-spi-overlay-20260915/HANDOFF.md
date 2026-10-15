# Resident benchmark recording SPI

This isolated overlay adds explicit final-diagnostic reservation and execution to the existing shared runtime. It does not edit main, the frozen serving worker, Protocol, model math, source loader, resource floors or allocator policy. `integration.json` maps eleven runtime files and one new test file. The nine frozen diagnostic files are copied exactly; only `QwenResidentRuntime.swift` and the new `QwenResidentRecording.swift` add facade behavior.

The value-only API is imported with `@_spi(Benchmark) import DarkbloomClusterRuntime`:

```swift
let ready = try runtime.recordingReadiness() // ClusterWorkerReady?, idle only
let localCharge = try runtime.reserveRecording(requestID: id, request: request)
let result = try runtime.startRecording(requestID: id, onCommittedToken: callback)
// result.completion: existing QwenResidentGenerationCompletion
// result.encodedEvidence: bounded CPU Data
```

Both rank owners must use the recording path and aggregate their returned local charges. The caller's capacity ceiling remains mandatory. The normal worker uses the unchanged serving APIs and cannot silently upgrade a serving reservation to recording. No diagnostic mode or evidence field is added to the pipe protocol. A private benchmark caller and durable sidecar sink remain separate work.

Mode binding is local to each reservation. The native bilateral agreement does not encode recording mode; the benchmark caller must select recording on both ranks and require both retained diagnostic outputs. This SPI does not claim bilateral diagnostic-mode agreement.

Recording readiness follows the existing bilateral loaded state and retains its identity/profile/Plan fields. Under the operation lock it derives the maximum original allowance at the admitted context/chunk limits, then adds the actual per-array diagnostic host/native terms. It allocates no request state and is a named capacity ceiling, not current resource admission. Busy, expired, failed or released owners cannot provide recording readiness.

Reservation retains the explicit mode, original state/fusion allowance and checked combined charge `B + H + A`. Rank 0 has no extra logit row; rank 1 charges both CPU row copies and both independently bounded native row arrays. The current BF16 vocabulary has 1,489,920 named host bytes; native array bounds are obtained from the actual allocator. The maximum and per-request charges must fit readiness and caller ceilings. The existing diagnostic gate binds the actual loaded source/profile/Plan and rederives the original request allowance before enforcing live free-memory/allocator/power checks. Its budget must equal the stored charge. Start checks mode and rederives the capture charge before any diagnostic request state, and checks the returned capture budget again after retirement.

Serving and recording share the existing operation lock, request agreement, lifecycle and autorelease scope. Serving calls the nil-diagnostic driver; recording calls the frozen diagnostic driver with the actual loaded stage/profile and the retained original allowance. The driver returns CPU evidence only after the existing bilateral retirement. The shared publication helper then observes local lifecycle exit, checks the deadline, prepares output (including diagnostic encoding), checks cancellation/deadline again, and only then completes control/restores capacity. Capture or encode errors preserve the original error and make the owner unavailable. A start using the wrong UUID or mode refuses without executing; it does not consume a matching reservation through a different entry point.

The final evidence encoding is capped at 16 MiB by the frozen encoder. This is an output cap, not a bound on intermediate serialization or metadata allocation. Named allowances and headroom are not whole-process peak proofs. Returned Data is owned by the caller after completion; retain or publish it under the caller's own memory/output bounds. Durable publication is outside this SPI and cannot be claimed from its return alone. Diagnostic capture/encoding time is not serving TTFT or throughput. The result makes no independent numerical or physical-transfer qualification claim.

Nine new CPU tests exercise the production charge and publication helpers with fabricated allocator/native/encoding callbacks: asymmetric per-rank charges, exact and one-byte-short ceilings, overflow and original allocator errors, substituted capture budgets, mode mismatch, capacity held through local scope retirement and output preparation, capture failure, post-retirement encoding failure, cancellation during encoding, and expired admission before the body runs. They do not call an MLX allocator, load weights or prove native retirement. The inherited facade tests and the separately frozen diagnostic fixtures retain their original scope.

Source checks verify all nine diagnostic hashes and the unchanged facade initializer, normal readiness, cancellation, shutdown and deinit sections. The isolated macOS 14 shared-library build and tests passed on the first attempt: 105.78 seconds to build, 107.742 seconds total, 12 inherited facade tests plus 9 recording tests, no failures and all source/lock pins unchanged. The actual command used `swift test --jobs 2 --disable-index-store --disable-automatic-resolution --skip-update --filter 'ResidentFacadeTests|ResidentRecordingTests'`, with the existing pinned `DARKBLOOM_RETAINED_PROFILE_FIXTURE`. Execution receipt: `resident-benchmark-recording-spi-build-20260915/tests-1/execution.json`, SHA `12ce5263ffb44e4fdd19f7db8fcdac307e6e10daf2e312331209e5fc79ce3cd8`. Existing SwiftPM dependency/exclude and deprecated-flag warnings are retained in stderr. This build checks the actual MLX Swift types but does not qualify JACCL transport. The separately built native worker remains macOS 26.2 and is unchanged by this overlay.

The next full-reference caller is still the reviewed experimental full-model entry described in `benchmark-generation-spi-map-20260915/PLAN.md`. This overlay does not duplicate its loader or add a default capture path.
