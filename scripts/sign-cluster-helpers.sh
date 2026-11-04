#!/bin/bash
# Sign (or, with --verify, only check) the cluster helpers inside a staged
# Darkbloom.app with the Developer ID identity, before the app itself is
# signed: hardened runtime, timestamp, their own identifiers and the
# network-only entitlements of provider-swift/entitlements-cluster-worker.plist.
# Developer ID is what keeps macOS's one-time approvals (application firewall
# "allow signed software", Local Network through the responsible app) from
# being asked again for every build (S18, permissions approved once).
#
# This is the OWNER step: it needs the Developer ID certificate in a keychain.
# The release workflows call it; an owner signing a local build calls it the
# same way, then signs the app and notarizes it as the workflow does.
#
# usage: sign-cluster-helpers.sh APP KEYCHAIN IDENTITY TEAM_ID ENTITLEMENTS
#        sign-cluster-helpers.sh --verify APP TEAM_ID
set -euo pipefail
helpers=(darkbloom-cluster-worker darkbloom-cluster-plan)
resources=(mlx.metallib pagedattention.metal)
verify_only=0
if [[ "${1:-}" == --verify ]]; then
  verify_only=1
  shift
  [[ $# == 2 ]] || { echo 'usage: sign-cluster-helpers.sh --verify APP TEAM_ID' >&2; exit 2; }
  app="$1"; team="$2"
else
  [[ $# == 5 ]] || { echo 'usage: sign-cluster-helpers.sh APP KEYCHAIN IDENTITY TEAM_ID ENTITLEMENTS' >&2; exit 2; }
  app="$1"; keychain="$2"; identity="$3"; team="$4"; entitlements="$5"
  [[ -f "$entitlements" && ! -L "$entitlements" ]] || { echo 'Missing cluster worker entitlements' >&2; exit 2; }
fi
directory="$app/Contents/Helpers"
for name in "${helpers[@]}" "${resources[@]}"; do
  path="$directory/$name"
  if [[ ! -f "$path" || -L "$path" || ! -s "$path" ]]; then
    echo "::error::Darkbloom.app/Contents/Helpers/$name is missing: the release must ship the cluster helpers" >&2
    exit 1
  fi
done
if [[ "$verify_only" == 0 ]]; then
  # Resources first: a nested code location may hold no unsigned file.
  for name in "${resources[@]}"; do
    codesign --force --options runtime --timestamp \
      --keychain "$keychain" --sign "$identity" "$directory/$name"
  done
  for name in "${helpers[@]}"; do
    codesign --force --options runtime --timestamp \
      --identifier "io.darkbloom.$name" \
      --entitlements "$entitlements" \
      --keychain "$keychain" --sign "$identity" "$directory/$name"
  done
fi
for name in "${helpers[@]}"; do
  codesign --verify --strict --verbose=2 \
    "-R=anchor apple generic and identifier \"io.darkbloom.$name\" and certificate leaf[subject.OU] = \"$team\"" \
    "$directory/$name"
done
for name in "${resources[@]}"; do
  codesign --verify --strict --verbose=2 "$directory/$name"
done
cmp "$directory/mlx.metallib" "$app/Contents/MacOS/mlx.metallib"
