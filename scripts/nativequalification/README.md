# Local App Attest Qualification

This is an explicitly authorized physical diagnostic, not a release, installer,
daemon, production enrollment, or serving authorization bypass. Signing uses an
existing local Developer ID identity and an already approved matching profile.
No keys are imported and no artifacts are uploaded or notarized by this helper.

## Qualification Status

As of 2026-10-11, the **reported Stage D native gate is FAIL**: the signed worker
on an M4 Max running macOS 27 reports `isSupported == false`. No Apple proof has
been accepted for this candidate, and no two-minute engine/resumption
qualification has completed. This is not a resolved generic unsupported-OS
condition, a qualified build, or a production-ready worker. The internal
`DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION` selection defaults to `false`;
see [configuration](../../docs/reference/configuration.md#app-attest-worker-qualification).

| Evidence | Current scope / pending result |
|---|---|
| Preserved candidate source | `1ff9e002a`; later diagnostics/build-source changes require their own source-bound validation |
| Earlier focused tests | 162 tests reported passed for the earlier source; not a current full-suite pass, Apple acceptance or coverage of the newer Stage D diagnostics/build-source edits |
| Worker support diagnostics | Current edits are untested at this checkpoint; rebuilt tests and a fresh signed native run are **pending** |
| Apple proof and recovery | Accepted enrollment/assertions, exact signed-code measurements and post-retirement recovery are **pending**, not implied by successful signing or IPC checks |
| Two-minute engine qualification | **Pending**; this diagnostic loads no model and cannot supply that result |

Record the final source/artifact-bound commands, literal outcomes and limitations
in the canonical dated qualification report when available. Do not replace this
failed checkpoint with inferred success, or reuse older counts for newly edited
source. No new native run is claimed by this documentation update.

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

This test deliberately loads **no model**, advertises no serving privacy grant,
and does not claim engine/inference or composed-coordinator resumption coverage.
The independent real 120-second resumption qualification must use the completed
platform integration and legitimate full runtime authorization; never seed a
fake serving grant to make this proof test appear to cover that requirement.
