#!/bin/bash
# The link-proxied follower endpoint (S08) and the combined owner profile (S07)
# across two processes over the link control channel on loopback: this process
# is the leader (rank 0 through its own stand-in owner, rank 1 through
# ClusterLinkWorkerEndpoint), a second process serves rank 1 through
# ClusterLinkWorkerServer and its stand-in owner. No SSH, no MLX, no model.
# A loopback pass is not a hardware pass.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "/private/tmp/cluster-link-worker.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macos14.0"
flags=(-j 4 -swift-version 6 -warnings-as-errors -target "$task_target")
for task_module in DarkbloomClusterProtocol DarkbloomClusterBootstrap DarkbloomClusterProcess DarkbloomClusterSecurity DarkbloomClusterRemote; do
  task_links=()
  case "$task_module" in
    DarkbloomClusterProcess) task_links=(-lDarkbloomClusterProtocol) ;;
    DarkbloomClusterSecurity) task_links=(-lDarkbloomClusterBootstrap) ;;
    DarkbloomClusterRemote) task_links=(-lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap -lDarkbloomClusterSecurity) ;;
  esac
  xcrun swiftc "${flags[@]}" -enable-testing -emit-library -emit-module -module-name "$task_module" \
    -emit-module-path "$task_build/$task_module.swiftmodule" -I "$task_build" -L "$task_build" ${task_links[@]+"${task_links[@]}"} \
    -Xlinker -rpath -Xlinker "$task_build" "$task_root/Sources/$task_module"/*.swift -o "$task_build/lib$task_module.dylib"
done
all_links=(-I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap
  -lDarkbloomClusterSecurity -lDarkbloomClusterRemote -Xlinker -rpath -Xlinker "$task_build")
fixture="$task_root/Tests/ProcessChecks/FixtureIdentity.swift"
xcrun swiftc "${flags[@]}" -parse-as-library -D FAKE_WORKER_PRELUDE "${all_links[@]}" \
  "$fixture" "$task_root/Tests/ProcessChecks/FakeClusterWorker.swift" -o "$task_build/fake-worker"
xcrun swiftc "${flags[@]}" -parse-as-library "${all_links[@]}" "$fixture" "$task_root/Tests/SSHChecks/FakeOwner.swift" -o "$task_build/fake-owner"
xcrun swiftc "${flags[@]}" -parse-as-library "${all_links[@]}" "$fixture" \
  "$task_root/Tests/LinkWorkerChecks/LinkWorkerFollower.swift" -o "$task_build/link-follower"
xcrun swiftc "${flags[@]}" -parse-as-library "${all_links[@]}" "$fixture" "$task_root/Tests/LinkWorkerChecks/NativeStartFixture.swift" \
  "$task_root/Tests/LinkWorkerChecks/LinkWorkerPairCheck.swift" -o "$task_build/link-pair-check"
"$task_build/link-pair-check" "$task_build/link-follower" "$task_build/fake-owner" "$task_build/fake-worker"
