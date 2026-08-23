# Darkbloom macOS sandbox runtime

This package is the isolated macOS host substrate for Darkbloom sandboxes. It
does not link the inference provider or MLX. The current executable slice:

- validates Apple Silicon, Virtualization.framework, capacity, Aqua-session,
  Secure Enclave, and code-signing prerequisites;
- resolves the latest host-supported macOS restore image through Apple's
  Virtualization.framework API;
- defines fenced sandbox identities, resource limits, lifecycle transitions,
  and a runtime boundary for VM implementations;
- provides chunked authenticated encryption for large VM artifacts; and
- wraps data-encryption keys with a distinct Secure Enclave identity.

The VM installer, guest agent, packet gateway, and coordinator lease protocol
will sit behind the interfaces in this package. Until those paths exist and
their live tests pass, this package is a host-substrate proof, not a
multi-tenant service.

## Build and test

The package requires Apple Silicon macOS 14 or newer with a full Xcode
toolchain.

```bash
swift build --package-path sandbox-macos
swift test --package-path sandbox-macos
```

The Apple restore-catalog test is opt-in because it makes a live network
request:

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
