# App Attest release-build disconnect investigation

> Last updated: 2026-09-14 · commit `2232503f8`

The published provider 0.9.3 aborts in the App Attest callback deadline's generic
`Task.sleep(for:)` cleanup. The exact release binary reproduced the production
disconnect sequence twice on macOS 27; both crash reports identify
`CallbackDeadline.call` followed by `swift_task_dealloc` and SIGABRT. Production
App Attest was paused. This report distinguishes that client failure from the
retained proof and receipt validation outcomes.

## Confirmed failure

The release workflow used Xcode 26.6 and Apple Swift 6.3.3. The published binary
SHA-256 is `28a8179179a6f8b88f463314f79e5238e6b31df7085293bf5a8c0acd67383d7e`;
the bundle SHA-256 is
`cea8c6e49b91aaaf7bdb07d24f01174344e03b0eb7664375e0c6b4258625dc99`.
The downloaded bundle matched those hashes and its signature verified after
extraction with macOS tar, preserving the signed resource metadata.

Two isolated launches of that full provider, with a loopback coordinator,
separate filesystem state and test authentication, returned `ready: ok` and then
aborted after the `attest` request. No consumer inference or production provider
connection was involved. The local Mac reported macOS 27.0 build `26A428`.

The stderr diagnostic was `freed pointer was not the last allocation`.
Both macOS crash reports contain this failing path:

```text
CallbackDeadline.call: timeout task closure
swift_task_dealloc
swift_Concurrency_fatalError
abort / SIGABRT
```

The timeout starts a sleeping Swift task and cancels it when Apple's callback
completes. Its optimized Duration/Clock sleep specialization can corrupt the
task allocator's last-in-first-out teardown. This matches the upstream
[Task.sleep specialization issue](https://github.com/swiftlang/swift/issues/86204)
and the workaround already documented in
`provider-swift/Sources/ProviderCore/TaskSleep.swift`. The new ProviderAppAttest
module used the generic overload in both its callback timer and retry delay.

Shadow mode excludes App Attest results from serving authorization. It does not
isolate the Apple adapter or its deadline task in a separate process. A fatal
runtime abort therefore terminates the provider and its serving WebSocket.

## Observed scenarios

| Scenario | Sequence and outcome |
|---|---|
| Unsupported OS | `prepare` returns `unsupported` before Apple key generation or deadline creation. macOS 26 providers running 0.9.3 were observed completing requests. |
| Fresh or unregistered key | `prepare` succeeds; callback/deadline cleanup races subsequent `attest` handling. The released client reproduced SIGABRT and the server observed an abrupt connection close. |
| Proof produced before the crash | Scheduling sometimes lets the proof reach local persistence or the coordinator before the deadline task aborts. This accounts for successful cryptographic records coexisting with disconnect events. |
| Assertion after enrollment | Production recorded a verified enrollment followed by a disconnected assertion exchange. A later assertion submission was archived with `storage_error`; its signature verifies offline. |
| Retry after reconnect | A cached enrollment proof can be returned after restart. Seven retained receipts arrived 362.865–466.948 seconds after Apple's creation time, exceeding the validator's five-minute limit and producing `receipt_creation_time`. |

The initial 31-event socket-log sample consisted entirely of abrupt EOFs without
a peer close frame. Request-to-disconnect delays were 2.54–3372.71 ms, median
1153.13 ms. By the containment preflight at 04:02:35 UTC, 34 machine identities
had recorded attestation/assertion disconnects. All reported macOS 27 and provider
0.9.3; hardware spanned M1–M5 chips with 24–128 GB RAM. Reconnects count as
additional sessions, not additional physical machines.

The local reproductions establish the concrete client failure behind this
pattern; matching crash reports were not collected from every affected Mac.
Server-side EOF alone cannot establish a process crash for each individual event.

## Retained evidence

Read-only production inspection found 14 submission records and 14 associated
blob rows: 13 nonempty proof payloads and one Apple-invalid-key response without
a proof. No archived record lacked its blob row. Eleven receipt bodies remained
stored, including failed validation outcomes. Nothing was purged by pausing.

Offline replay through the unchanged production verifier validated all twelve
nonempty attestation payloads and the one assertion (counter 1), using each
record's retained client-data hash and verification inputs. The production
statuses remained ten verified attestations, one pending attestation, one
attestation with `storage_error`, one Apple-invalid-key response, and an assertion
with `storage_error`. Offline verification did not rewrite production outcomes
or counters. Storage outcomes must not be interpreted as cryptographic rejection.

The seven receipt-time failures were checked against their signed receipt
creation times. All were older than 300 seconds at receipt; none needed a clock
skew or malformed timestamp explanation. The strict receipt freshness policy
and cached-enrollment recovery have different time windows. No validator
freshness rule was relaxed during this investigation.

## Containment and qualification boundary

The approved coordinator recreate set
`EIGENINFERENCE_APP_ATTEST_SHADOW=false`, preserving the 0.9.3 image, APNs/MDM,
Global Payouts=false, userdata, cache controls and Caddy. It became ready at
04:03:39 UTC. No new shadow events were recorded after startup.

At 04:05:47 UTC, 15 of the frozen 34 affected identities had reconnected; three
had completed 15 requests. The network had completed 4199 requests after the
restart. Those are bounded recovery observations, not proof that every machine
recovered or that every historical EOF had the same cause.

The remediation replaces generic sleeps in ProviderAppAttest with the existing
non-generic nanoseconds workaround and adds a callback/deadline exercise to
`runtime-smoke`. Release packaging requires its success marker before upload.
The probe uses synthetic callbacks and no Apple service, Keychain or network
request, so it can exercise the optimized linked binary independently of host
App Attest support. Debug unit tests and GPU-only package smoke did not cover
the failing release-runtime path.

## Remediation validation

The local candidate used Apple Swift 6.3.3, an optimized full-provider build,
the released app's resources/profile, and Developer ID signing. It was an
isolated test artifact, not a notarized public release. Its signed executable
SHA-256 was
`10b56951c774a9e8a19efea4bf2a79a58ce8173dc5ca08b276ce2844e8825a13`.

| Check | Observed result |
|---|---|
| Published 0.9.3, two full-client runs | Both aborted with SIGABRT in the callback deadline's sleep cleanup. |
| Fixed optimized app, packaged smoke | Callback completion/expiry, Gemma configuration and paged-kernel checks passed. |
| Real Apple enrollment with fixed app | Complete attestation verified with the coordinator's unchanged production-root verifier. |
| Assertions on the same connection | Three encrypted-challenge assertions verified, counters 1–3. |
| Provider/server harness restart | The same saved key was reused without another attestation; counters 4–6 verified. |
| Process survival | The fixed client stayed alive after the exchanges; only the harness's intentional SIGTERM ended each trial. |
| Negative control of the new package gate | Restoring only the old generic callback-timer sleep and rebuilding caused `runtime-smoke` itself to abort with the same allocator diagnostic. No Apple API was needed. |
| Existing regression suites | 17 ProviderAppAttest tests and two CLI-dispatch tests passed. |

The negative control used the same local compiler, source tree and fully linked
dependencies as the passing candidate. The fixed source was restored afterward.
These checks isolate the timer overload as the regression and demonstrate that
the new package gate catches it. They do not certify every hardware/OS cohort or
constitute permission to publish or re-enable production App Attest.

Production must remain paused pending qualification and an explicitly approved
provider release and re-enable operation. The timer fix does not itself resolve
receipt renewal configuration or retrospectively finalize pending storage rows.
