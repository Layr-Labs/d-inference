#!/usr/bin/env bash
# Release-toolchain wrapper; normal developer and PR CI commands remain separate.
set -euo pipefail
: "${PROVIDER_SWIFT:?Select the provider release toolchain first}"
: "${PROVIDER_SDKROOT:?Select the provider release SDK first}"
export SDKROOT="$PROVIDER_SDKROOT"
if [[ $# -eq 0 ]]; then exec "$PROVIDER_SWIFT"; fi
swift_command="$1"
shift
case "$swift_command" in
  build|test)
    exec "$PROVIDER_SWIFT" "$swift_command" --build-system native --sdk "$SDKROOT" "$@"
    ;;
  *) exec "$PROVIDER_SWIFT" "$swift_command" "$@" ;;
esac
