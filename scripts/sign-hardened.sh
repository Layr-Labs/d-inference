#!/bin/bash
#
# Sign EigenInference binaries with macOS Hardened Runtime.
#
# Hardened Runtime is the CRITICAL piece that prevents debugger attachment
# and memory inspection even with SIP enabled. Without it, our PT_DENY_ATTACH
# and SIP checks are insufficient — any process can read our memory via
# task_for_pid / mach_vm_read.
#
# With Hardened Runtime (--options runtime) and WITHOUT get-task-allow:
#   - task_for_pid() fails for any external process trying to inspect us
#   - lldb/dtrace cannot attach
#   - mach_vm_read() from other processes is denied by the kernel
#   - This is enforced by the kernel as long as SIP is enabled
#
# Usage:
#   ./scripts/sign-hardened.sh              # Sign with ad-hoc identity (testing)
#   ./scripts/sign-hardened.sh "Developer ID Application: YourOrg"  # Sign with real identity
#
# Prerequisites:
#   - Xcode Command Line Tools installed
#   - For distribution: Apple Developer ID certificate in Keychain

set -euo pipefail

IDENTITY="${1:--}"  # Default to ad-hoc signing if no identity provided
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

# Use the canonical entitlements file. The release workflow already signs with
# `scripts/entitlements.plist`; overwriting it here silently drops required
# entitlements and makes local validation diverge from the shipped artifacts.
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "ERROR: $ENTITLEMENTS missing — keep it under source control."
    exit 1
fi

echo "=== EigenInference Hardened Runtime Signing ==="
echo "Identity: $IDENTITY"
echo "Entitlements: $ENTITLEMENTS"
echo ""

# Sign provider binary
PROVIDER_BIN="$PROJECT_DIR/provider/target/release/darkbloom"
if [ -f "$PROVIDER_BIN" ]; then
    echo "Signing darkbloom..."
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" \
        "$PROVIDER_BIN"
    echo "  Verifying..."
    codesign --verify --verbose=2 "$PROVIDER_BIN" 2>&1 | head -5
    echo "  Hardened Runtime flags:"
    codesign --display --verbose=2 "$PROVIDER_BIN" 2>&1 | grep -i "runtime\|flags"
    echo ""
else
    echo "WARNING: darkbloom binary not found at $PROVIDER_BIN"
    echo "  Build first with: cd provider && cargo build --release"
    echo ""
fi

# Sign enclave CLI binary
ENCLAVE_BIN="$PROJECT_DIR/enclave/.build/release/eigeninference-enclave"
if [ -f "$ENCLAVE_BIN" ]; then
    echo "Signing eigeninference-enclave..."
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" \
        "$ENCLAVE_BIN"
    echo "  Verifying..."
    codesign --verify --verbose=2 "$ENCLAVE_BIN" 2>&1 | head -5
    echo ""
else
    echo "WARNING: eigeninference-enclave binary not found at $ENCLAVE_BIN"
    echo "  Build first with: cd enclave && swift build -c release"
    echo ""
fi

echo "=== Signing complete ==="
echo ""
echo "IMPORTANT: For production distribution, use a Developer ID certificate"
echo "and notarize the binaries with:"
echo "  xcrun notarytool submit <binary> --apple-id <email> --team-id <team>"
echo ""
echo "For testing, ad-hoc signed binaries work on the local machine."
echo "Hardened Runtime protections are active regardless of signing identity"
echo "as long as SIP is enabled."
