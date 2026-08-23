# Darkbloom macOS sandbox runtime

This package is the isolated macOS host substrate for Darkbloom sandboxes. It
does not link the inference provider or MLX. The current executable slice:

- validates Apple Silicon, Virtualization.framework, capacity, Aqua-session,
  Secure Enclave, and code-signing prerequisites;
- resolves the latest host-supported macOS restore image through Apple's
  Virtualization.framework API;
- invokes an audited, exact-commit Lume build behind a narrow runtime adapter
  for the macOS 26 unattended-install proof;
- defines fenced sandbox identities, resource limits, lifecycle transitions,
  and a runtime boundary for VM implementations;
- provides chunked authenticated encryption for large VM artifacts; and
- wraps data-encryption keys with a distinct Secure Enclave identity.

The VM installer, guest agent, packet gateway, and coordinator lease protocol
will sit behind the interfaces in this package. Lume's temporary unattended
guest uses its known `lume` / `lume` bootstrap credentials, so this slice is
restricted to the approved no-secrets alpha. Until randomized bootstrap
credentials, guest control, egress enforcement, and leases pass their live
tests, this package is a host-substrate proof, not a multi-tenant service.

## Build and test

The package requires Apple Silicon macOS 14 or newer with a full Xcode
toolchain.

```bash
swift build --package-path sandbox-macos
swift test --package-path sandbox-macos
```

The Apple restore-catalog test is opt-in because it makes a live network
request. SwiftPM does not attach custom entitlements to its XCTest runner, so
the test ad-hoc signs the package's debug daemon with
`com.apple.security.virtualization` and executes the real
`VZMacOSRestoreImage.fetchLatestSupported` path in that entitled process:

```bash
DARKBLOOM_SANDBOX_LIVE_RESTORE=1 swift test \
  --package-path sandbox-macos \
  --filter SandboxRuntimeVZTests
```

## Host proof

Sign the debug executable with the sandbox entitlements before running the
strict host check:

```bash
bin_path="$(swift build --package-path sandbox-macos --show-bin-path)"
codesign --force --sign - \
  --entitlements sandbox-macos/Resources/DarkbloomSandbox.entitlements \
  "$bin_path/darkbloom-sandboxd"
"$bin_path/darkbloom-sandboxd" doctor --json
"$bin_path/darkbloom-sandboxd" restore-image latest --json
```

`--development-unsigned` downgrades only the missing virtualization entitlement
to a warning. It does not bypass architecture, hypervisor, capacity, Aqua, or
Secure Enclave checks.

Production persistence uses the dedicated
`SLDQ2GJ6TL.io.darkbloom.sandbox` keychain access group. Ad-hoc signatures can
exercise transient Secure Enclave cryptography but cannot prove production
keychain persistence; that path must be verified with the provisioned release
identity.

## Pinned Lume substrate

`ThirdParty/lume.lock.json` pins the exact Cua source commit and expected
version. Build it without a background service:

```bash
sandbox-macos/Scripts/build-pinned-lume.sh \
  "$HOME/.local/libexec/darkbloom-sandbox/lume/bin"
```

The adapter sets `LUME_TELEMETRY_ENABLED=false` for every invocation and rejects
any runtime version other than the lock. Moving the pin requires source review
plus the opt-in real-binary and VM lifecycle tests.

```bash
DARKBLOOM_SANDBOX_LUME_PATH=/absolute/path/to/lume \
  swift test --package-path sandbox-macos \
  --filter LumeRuntimeContractTests
```
