#!/bin/bash
# Actual runtime catalog metadata and command admission. MLX is linked because
# the catalog describes all families; no model or GPU work is executed.
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_shared="$(cd "$task_package/../darkbloom-cluster" && pwd)"
bash "$task_shared/Tests/Support/native-metadata.sh" capability \
  "$task_package/Tests/CapabilityChecks/Fixtures" \
  "$task_shared/Tests/CapabilityChecks/Fixtures/registered-qwen35-9b.capability.json"
