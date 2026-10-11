# Local App Attest Qualification

This is an explicitly authorized physical diagnostic, not a release, installer,
daemon, production enrollment, or serving authorization bypass. Signing uses an
existing local Developer ID identity and an already approved matching profile.
No keys are imported and no artifacts are uploaded or notarized by this helper.

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
The production 80-second deadline must kill/reap that worker before a fresh
prepare can launch its replacement. The real Apple-root verifier checks both
assertions and increasing counters against the same credential, including the
actual signed artifact's type-2 CodeDirectory measurement and replay/hash
negative controls.

This test deliberately loads **no model**, advertises no serving privacy grant,
and does not claim engine/inference or composed-coordinator resumption coverage.
The independent real 120-second resumption qualification must use the completed
platform integration and legitimate full runtime authorization; never seed a
fake serving grant to make this proof test appear to cover that requirement.
