# Local App Attest Qualification

This is an explicitly authorized physical diagnostic, not a release, installer,
daemon, production enrollment, or serving authorization bypass. Signing uses an
existing local Developer ID identity and an already approved matching profile.
No keys are imported and no artifacts are uploaded or notarized by this helper.

## Qualification Status

As of 2026-10-12, the suspended-worker and real assertion-callback components
have source/artifact-bound passes, and the separate
[full loaded-engine callback scenario passed](https://github.com/Layr-Labs/darkbloom-platform/blob/7e69b67aa4173e7af021de4f846e4c4667a25aed/docs/reports/2026-10-12-native-loaded-worker-callback-qualification.md)
on the same M4 Max (`Mac16,5`, macOS 27.0.1 `26A434`). All use Apple's real
service and the production-root Go verifier. The full scenario additionally
requires legitimate serving authorization and encrypted paid inference before,
strictly inside the callback/reap windows, and after fresh proof acceptance.
These passes do not complete the physical OS/update/reboot or fleet-rollout
matrix and do not qualify a later rebuilt binary. The internal
`DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION` selection defaults to `false`;
see [configuration](../../docs/reference/configuration.md#app-attest-worker-qualification).

| Evidence | Current scope / pending result |
|---|---|
| Suspended-worker component | Signed binary SHA-256 `566a0bb8114d1c3b164930f7e7f30be1fa7691acc193515e206ba45e38bac94a`; actual enrollment and two accepted assertions, replay/hash negatives, approximately 80-second deadline and confirmed reap before replacement |
| Precise callback component | Signed binary SHA-256 `9945083386bd57a45c84df7145563c2013966714dbc4b666c3252c7da5920222`; actual assertion invocation and discarded callback observed, real `operation_timeout`, reap after 25.15 / 25.32 seconds, replacement's same-credential assertion accepted |
| Signed code identity | Developer ID category 6 / type-2 CodeDirectory evidence matched the measured artifacts; callback artifact full CD hash `ceec7aac33a773b7ec01b065730642418833c426c8140bb94a7dbae47793d370` |
| Local tests | 107 App Attest + 6 CLI tests passed before the callback consumer addition; its focused 30-test check also passed. These are not a full provider-suite claim |
| Loaded-engine callback qualification | **PASS**, independently recorded in the linked October 12 report; the real serving loop retained its parent, endpoint and loaded model/engine through actual callback withholding and worker replacement |
| Two-minute engine resumption | **PASS in the separate [Stage C run](../../docs/reports/2026-10-11-native-serving-resumption-qualification.md)**; the component diagnostic below loads no model and cannot supply that result |

Earlier copied-artifact tests genuinely failed at `is_supported_false` in both
parent and child, even with matching effective grants. Adding the granted team
identity alone did not resolve this. Refreshing the **exact final signed test
app's LaunchServices registration** changed the unchanged callback artifact from
unsupported to two successful real-proof runs. The harness now performs this
scoped preparation and restores registration afterward. The earlier suspended
artifact also passed without the AppKit diagnostic host after its first hosted
run, so a per-process AppKit requirement is not inferred. No RDMA or OS security
setting was changed, and RDMA enablement is not treated as a disqualifier.

## Build And Sign

Wait for exclusive provider `.build` ownership and a source freeze. Build the
release configuration with the installed SDK 27 toolchain; keep `SDKROOT` set for
linking as well as compilation. The diagnostic rejects debug/unsigned binaries.

```bash
# From provider-swift; each native compilation needs a 20-minute timeout.
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" xcrun swift build \
  --build-system native --sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -c release --product darkbloom
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" xcrun swift build \
  --build-system native --sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -c release --product darkbloom-enclave
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" xcrun swift build \
  --build-system native --sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -c release --product darkbloom-fan-helper
```

From the provider repository root, supply the verified paths and current source
version. `OUTPUT` must be a new directory under this checkout's
`provider-swift/.build`. The helper checks/rebuilds source-matched kernels,
requires the supplied metallib to match, stages the normal resource bundles,
validates the profile, and signs and verifies the complete app. The profile's
decoded intermediate stays private under `OUTPUT`; never publish that directory.

```bash
DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION=1 \
  bash scripts/nativequalification/stage-signed-app.sh \
  "$BIN" "$METALLIB" "$OUTPUT" "$PROFILE" "$SIGNING_IDENTITY" "$VERSION"
```

## Actual Apple Test

The counterpart lives only in the sibling **platform** repository at
`coordinator/tests/appattest/nativequalification`. From that repository:

```bash
DARKBLOOM_RUN_NATIVE_APP_ATTEST=1 \
DARKBLOOM_NATIVE_QUALIFICATION_APP="$OUTPUT/Darkbloom.app" \
  go test ./coordinator/tests/appattest/nativequalification \
  -run '^TestSignedWorkerRecovery$' -count=1 -v -timeout 6m
```

Use `-run '^TestSignedCallbackRecovery$'` for the precise callback-discard gate.
Set `DARKBLOOM_NATIVE_QUALIFICATION_APPKIT=1` only for the parent AppKit comparison.
That host validates the same private inputs and signed identity before startup,
captures support after `applicationDidFinishLaunching`, and registers no APNs.

After signature verification, the explicitly enabled harness snapshots existing
registered copies, refreshes only this `.build` candidate via `lsregister -f`,
and then launches it. Cleanup waits for the captured process first, unregisters
only a newly added candidate entry, and restores the previous preferred entry.
Already-registered copies are not removed. It never launches or edits the
operator's installed bundle or changes a system security setting. Signing and
registration must refer to the same final bytes.

Without opt-in the test skips. With opt-in, missing/invalid signed resources,
Apple refusal, absent code measurements, replay acceptance, or failed recovery
are failures, not skips. The test creates a fresh isolated local credential
scope; Apple's private key remains in its service and scoped lifecycle state
remains in Keychain. It does not read/delete operator authentication or App Attest
records. Every endpoint secret is generated internally and never exported.

The same signed main executable owns the normal `CoordinatorClient` and launches
its authenticated private worker. A fixed second-assertion fault asks the worker
supervisor to suspend its own captured child under its signalling/reaping lock;
no PID or arbitrary signing request is accepted from arguments or the network.
The candidate supervisor's fixed 80-second deadline must kill/reap that worker before a fresh
prepare can launch its replacement. When Apple support is available, the test
requires the real Apple-root verifier to check both
assertions and increasing counters against the same credential, including the
actual signed artifact's type-2 CodeDirectory measurement and replay/hash
negative controls.

The injected `SIGSTOP` is a **worker/IPC stall**, not evidence that a DeviceCheck
operation was invoked and its callback never returned. Keep these gates distinct:

| Required case | Evidence required before claiming it passes |
|---|---|
| IPC/suspended-worker deadline | Owned child is suspended, fixed deadline fires, termination and reap finish before replacement; parent/key unchanged |
| Native operation never calls back | A genuinely outstanding native Apple operation is recorded separately; kill/reap precedes a replacement worker's accepted proof, with no overlapping operation or parent restart |
| Engine continuity across a two-minute gap | Full authorized provider/engine run, same parent endpoint, actual inference before/after and the completed platform resumption checks; no fabricated serving grant |

`AppAttestWorkerRuntimeDiagnostics.capture` in
`provider-swift/Sources/ProviderAppAttest/Worker/AppAttestWorkerRuntimeDiagnostics.swift`
observes support before/after effective-entitlement inspection, dynamic signing
state, bundle and launch context only when no Apple operation is outstanding.
It does not initialize AppKit, register an app or generate a key. Its raw local
paths and entitlement observations stay in private qualification evidence, not
coordinator wire claims, authorization or public logs. The new diagnostic is not
evidence that the support failure is fixed.

The callback scenario uses `armNextAssertionCallbackDiscardForQualification`.
It accepts no PID, key, endpoint, or signing hash. The worker invokes the normal
real `SystemAppAttestCallbacks.generateAssertion` and deliberately never delivers
its callback to the caller. Two authenticated observations must identify the same
worker generation and assertion sequence: invocation submitted, callback
discarded. The normal 25-second deadline and production retirement path then run;
the old gate is never released. The runner forwards the actual timeout payload,
requires confirmed reap before a fresh prepare, and verifies the replacement's
assertion against the same Apple credential with increasing counters.

This component test deliberately loads **no model**, advertises no serving privacy grant,
and does not claim engine/inference or composed-coordinator resumption coverage.
The independent real 120-second resumption qualification must use the completed
platform integration and legitimate full runtime authorization; never seed a
fake serving grant to make this proof test appear to cover that requirement.

For the full loaded-engine callback case, use the platform's
`TestSignedProviderLoopLoadedEngineCallbackRecovery` with the explicit native
serving/model inputs in its [test procedure](https://github.com/Layr-Labs/darkbloom-platform/blob/7e69b67aa4173e7af021de4f846e4c4667a25aed/docs/developer/test.md#app-attest-endpoint-and-native-gates)
and `-timeout=20m`. Its child selects the existing serving qualification CLI
and both worker opt-ins. The owner-only `arm-worker-callback` marker is written
only after initial real proof and a warm engine; normal coordinator renewal and
retry timing remain unchanged. Independent safety/refactor review, frozen source,
exclusive GPU ownership and an exact signed artifact are prerequisites.
