#!/usr/bin/env bash
# Run from provider-swift after building tests and staging the matched metallib.
# Exact allocator assertions need their own process, without unrelated MLX work.
# Keep both outcomes: a failure in the general suite must not silence this gate.
set -uo pipefail
provider_test_status=0
swift test --skip-build --skip ProcessMemoryNativeIntegrationTests || provider_test_status=$?
../scripts/run-nested-suite.sh ProcessMemoryNativeIntegrationTests || provider_test_status=$?
exit "$provider_test_status"
