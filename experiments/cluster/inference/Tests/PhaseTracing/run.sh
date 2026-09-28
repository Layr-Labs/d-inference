#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source_dir="../../Sources/ClusterInference/Tracing"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-phase-checks.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc \
  "$source_dir/QwenPrefillPhaseTypes.swift" \
  "$source_dir/QwenPrefillPhaseRecorder.swift" \
  "$source_dir/QwenPrefillPhaseFile.swift" \
  "$source_dir/QwenPrefillPhaseCapture.swift" \
  "$source_dir/CBv2OwnerPhaseObservation.swift" CBv2OwnerPhaseObservationCheck.swift \
  "$source_dir/QwenPrefillOwnerTypes.swift" "$source_dir/QwenPrefillOwnerRecorder.swift" \
  "$source_dir/QwenPrefillOwnerCapture.swift" "$source_dir/QwenPrefillTraceCaptures.swift" \
  QwenPrefillOwnerRecorderCheck.swift QwenPrefillOwnerOutputCheck.swift \
  QwenPrefillPhaseRecorderCheck.swift QwenPrefillPhaseFileCheck.swift \
  QwenPrefillPhaseOutputCheck.swift main.swift -o "$check_dir/check"
"$check_dir/check"
