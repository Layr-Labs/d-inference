#!/usr/bin/env bash
# After a failed provider CI build: build once more from nothing only when the
# restored build came from the loose cache tier (another recipe, the same
# toolchain and dependencies). Exits 0 after deleting the restored builds, so
# the caller builds again; exits 1 when the failure is the build's own.
set -euo pipefail
matched=${PROVIDER_CI_MATCHED_KEY:-}
strict=${PROVIDER_CI_STRICT_PREFIX:?PROVIDER_CI_STRICT_PREFIX is required}
root=${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}
case $matched in
  "")
    echo "The build failed without a restored cache entry; not building again."
    exit 1 ;;
  "$strict"*)
    echo "The build failed over a cache entry of this recipe ($matched); not building again."
    exit 1 ;;
esac
echo "::warning title=Build cache::The build failed over a cache entry of another recipe ($matched). Deleting the restored builds and building once from nothing."
rm -rf "$root/provider-swift/.build" "$root/libs/darkbloom-cluster/.build"
