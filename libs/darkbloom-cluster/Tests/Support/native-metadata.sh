#!/bin/bash
# The closed catalog includes every runtime family, including metadata whose
# types live in MLXLLM. Link the actual Runtime; execute only metadata/argument
# checks. This is not a model, GPU, native transport or performance test.
set -euo pipefail
task_shared="$(cd "$(dirname "$0")/../.." && pwd)"
task_worker="$(cd "$task_shared/../darkbloom-cluster-worker" && pwd)"
task_product="${1:?Expected capability or bootstrap}"
shift
case "$task_product" in capability|bootstrap) ;; *) echo 'Expected capability or bootstrap' >&2; exit 2 ;; esac
task_temporary="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
# A caller may retain an isolated build directory to reuse the native build
# across these two suites. Never point this at provider or worker build products.
if [[ -n "${DARKBLOOM_CLUSTER_METADATA_BUILD_ROOT:-}" ]]; then
  task_build="$DARKBLOOM_CLUSTER_METADATA_BUILD_ROOT"
  mkdir -p "$task_build"
  task_build="$(cd "$task_build" && pwd -P)"
else
  task_build="$(mktemp -d "$task_temporary/cluster-native-metadata.XXXXXXXX")"
  trap 'rm -rf "$task_build"' EXIT
fi
chmod 700 "$task_build"
/usr/bin/python3 - "$task_shared" "$task_worker" "$task_build" <<'PY'
from pathlib import Path
import json, shutil, sys
shared, worker, build = map(Path, sys.argv[1:])
package = build / 'package'
package.mkdir(exist_ok=True)
closures = {
    'capability': [worker / 'Sources/DarkbloomClusterWorker/Capabilities' / name for name in
                   ('WorkerCapabilityInput.swift', 'WorkerCapabilityCommand.swift')] +
                  [worker / 'Tests/CapabilityChecks' / name for name in
                   ('CapabilityCheckSupport.swift', 'CapabilityInputCheck.swift', 'CapabilityCommandCheck.swift')],
    'bootstrap': [worker / 'Sources/DarkbloomClusterWorker/Startup' / name for name in
                  ('WorkerConfiguration.swift', 'WorkerBootstrapConfiguration.swift', 'GLM5NextWorkerQualification.swift')] +
                 [worker / 'Sources/DarkbloomClusterWorker/Capabilities/WorkerCapabilityInput.swift'] +
                 [shared / 'Tests/BootstrapChecks/Channel/WorkerBootstrapAdmissionCheck.swift'],
}
for target, sources in closures.items():
    destination = package / 'Sources' / target
    destination.mkdir(parents=True, exist_ok=True)
    expected = {source.name for source in sources}
    for previous in destination.glob('*.swift'):
        if previous.name not in expected:
            previous.unlink()
    for source in sources:
        output = destination / source.name
        data = source.read_bytes()
        if not output.exists() or output.read_bytes() != data:
            output.write_bytes(data)
# Bootstrap copies production worker sources, including qualification metadata.
# Use their normal warning policy: existing production deprecations are not
# new test failures. The capability fixture itself remains warnings-as-errors.
manifest = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ClusterNativeMetadataChecks", platforms: [.macOS(.v14)],
    dependencies: [.package(path: SHARED)],
    targets: [
        .executableTarget(name: "capability", dependencies: [
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster")],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .executableTarget(name: "bootstrap", dependencies: [
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterSecurity", package: "darkbloom-cluster")])
    ])
'''.replace('SHARED', json.dumps(str(shared)))
path = package / 'Package.swift'
if not path.exists() or path.read_text() != manifest:
    path.write_text(manifest)
# Keep the same external dependency revisions as the native worker build.
resolved = package / 'Package.resolved'
pinned = worker / 'Package.resolved'
if not resolved.exists() or resolved.read_bytes() != pinned.read_bytes():
    shutil.copyfile(pinned, resolved)
PY
# Four jobs by default keeps a developer Mac usable; a dedicated CI runner sets more.
task_jobs="${DARKBLOOM_CLUSTER_METADATA_BUILD_JOBS:-4}"
[[ "$task_jobs" =~ ^[1-9][0-9]*$ ]] || { echo 'DARKBLOOM_CLUSTER_METADATA_BUILD_JOBS must be a positive integer' >&2; exit 2; }
swift build --package-path "$task_build/package" --scratch-path "$task_build/build" \
  -c release --jobs "$task_jobs" --force-resolved-versions --product "$task_product"
task_binary="$task_build/build/release/$task_product"
"$task_binary" "$@"
if [[ "$task_product" == capability ]]; then
  /usr/bin/python3 "$task_worker/Tests/CapabilityChecks/check_command.py" "$task_binary" "$task_worker/Tests/CapabilityChecks/Fixtures"
fi
