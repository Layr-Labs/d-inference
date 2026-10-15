# Distributed local HTTP host

This adds four ProviderCore server files and two test files. It uses the normal `makeLocalInferenceApplication` HTTP stack with one `DistributedInstalledSession`, its verified tokenizer metadata, and `DistributedEngineFactory.makeRegistryEntry`. No local model container or weights are loaded. MAIN and earlier frozen artifacts are unchanged.

## CLI integration

```swift
let session = try DistributedInstalledSession.prepare(reference: reference)
let server = DistributedLocalServer(
    session: session,
    config: .init(host: host, port: port, authToken: token),
    firstTokenBudgetPolicy: try .init(baseMilliseconds: 10_000, millisecondsPerInputToken: 1))
// Retain server across this call's failure and throughout teardown.
try await server.start()
let status = await server.waitUntilStopped()
// status.cleanupComplete is required before discarding the host or rotating.
```

The policy is optional and defaults to nil. When chosen, it uses the already integrated HTTP receipt origin and actual tokenized input count; it does not measure external client TTFT. The installed session verifies the explicit public route against pinned product metadata. Native identity is unchanged.

The CLI owns its serving/PID lock, sleep prevention and process signal scope before startup; it does **not** acquire a native device gate. The HTTP service passes `gracefulShutdownSignals: []`. Cancellation calls `await server.stop(until: absoluteLocalUptime)` while retaining the host. `start(bindTimeout:)` returns only after its own listener bind callback and discovery publication. A port collision cannot use another process's health response as readiness. Port zero records the actual assigned port.

## Lifetime and ownership

`DistributedLocalServerStatus` exposes `phase`, `publicModelID`, `boundPort`, `acquisitions`, `session`, `failed` and `cleanupComplete`. Phases are `prepared`, `starting`, `serving`, `draining`, `stopping`, `quarantined`, `stopped`. Cleanup requires `stopped`, installed status `released` and zero acquisition pins.

`stop(until:)` closes admissions and cancels. `drain(until:)` closes admissions then allows the installed session's current explicit request release before shutdown. Both deadlines bound the caller's wait; an incomplete wait returns quarantine while the retained teardown task continues, and publishes that explicit outcome to existing `waitUntilStopped()` observers. A later `stop` or fixed lifetime expiry interrupts a drain. `waitUntilStopped()` returns either completed listener/engine/session/pin cleanup or explicit retained quarantine (bounded stop expired/canceled, or installed teardown returned without the owner lease ACK). After quarantine, retain the host and observe `status.cleanupComplete` for any eventual completion; quarantine is not cleanup permission.

The fixed owner lifetime is read once after actual ready and never renewed. A bounded-sleep monitor checks expiry even without HTTP requests; native deadlines and owner watchdogs remain authoritative during blocked work. The host also stops when the session is invalid or exhausted between requests. It never replaces the session's engine invalidation handler. HTTP uses one acquisition at a time with `OneShotRelease`; unknown public routes return 404, unavailable/draining acquisition returns 503. No independent native byte reservation is invented.

Startup is joined before final teardown so a late tokenizer/load result cannot install a bridge afterward. Engine cancellation/retirement and session shutdown run while HTTP unwinds, avoiding a listener-first wait on a stream awaiting native retirement. The bridge, tokenizer and session remain retained through quarantine. The host starts no replacement epoch.

## Discovery and verification

Discovery is written only after actual bind and removed when admissions close, using the exact published `LocalEndpoint.Info`. A different record encountered during removal is preserved. This conditional read/remove relies on the existing CLI serving lock for cooperating publishers; it is not atomic protection against arbitrary same-user writers. The existing local token remains untouched by shutdown.

All six proposed sources passed Swift syntax parsing. Twelve ProviderCore tests are staged, **not executed here**: actual loopback HTTP public catalog/unknown route and bind conflict, pin retention, startup cancellation, idle expiry, owner ACK versus native cleanup/listener exit, bounded-stop observer quarantine and eventual cleanup, retained quarantine, competing discovery record, tokenizer revalidation before native start, drain refusal/release, last-response pin retention on request-count exhaustion, unexpected session loss, and invalid pair state before its status callback. These use fabricated sessions and tokenizers, no model/native child or remote network. Root owns full Provider typecheck/test execution and actual two-host HTTP acceptance. No measured throughput or external TTFT claim is made by this change.

The small internal `DistributedLocalServerSession` protocol exists only to inject those model-free tests. Production construction accepts the concrete installed session and projects its actual `admissionState` into host availability; the underlying owner rechecks atomic admission. Integrate together with transport's installed-session/model API in `distributed-installed-owner-draft` and current MAIN HTTP-origin/factory changes. No Package.swift change is needed.

V2 preserves the first frozen source snapshot (`distributed-local-server-draft-20260915`, manifest `f82193af0717d150813c50ca28ddedc705e65fc538d6948f72f43a953750c3e8`). Review found that unexpected session loss or an invalid pair could otherwise look like successful normal shutdown. V2 separates pair invalidity from request-count exhaustion and latches `failed` before teardown; later successful cleanup cannot clear that failure. Requested stop, fixed lifetime expiry and normal quota completion stay distinct.
