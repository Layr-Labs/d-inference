#!/bin/bash
set -euo pipefail
# Run only after the root coordinator grants the local compiler slot.
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$1"
mkdir -m 700 "$out"
runtime="$root/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime"
fixture="$root/proposed/libs/darkbloom-cluster-worker/Tests/MTPSelectedLoadCheck"
swiftc -swift-version 6 -warnings-as-errors "$runtime/QwenResidentMTPLoadPublication.swift" \
    "$root/Tests/PublicationCheck.swift" -o "$out/publication"
"$out/publication"
swiftc -swift-version 6 -warnings-as-errors "$fixture/SelectedLoadOutput.swift" \
    "$root/Tests/OutputCheck.swift" -o "$out/output"
"$out/output"
