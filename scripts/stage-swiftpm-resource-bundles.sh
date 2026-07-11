#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <swift-bin-dir> <app-bundle> <manifest-output>" >&2
  exit 64
fi

bin_dir=$1
app_bundle=$2
manifest=$3

[[ -d "$bin_dir" ]] || { echo "Swift bin directory does not exist: $bin_dir" >&2; exit 1; }
[[ -d "$app_bundle" ]] || { echo "App bundle does not exist: $app_bundle" >&2; exit 1; }
resource_root="$app_bundle/Contents/Resources"
mkdir -p "$resource_root"

shopt -s nullglob
bundles=("$bin_dir"/*.bundle)
(( ${#bundles[@]} > 0 )) || {
  echo "No SwiftPM resource bundles found beside the built executable: $bin_dir" >&2
  exit 1
}

: > "$manifest"
for source_bundle in "${bundles[@]}"; do
  [[ -d "$source_bundle" && ! -L "$source_bundle" ]] || {
    echo "SwiftPM resource bundle must be a real directory: $source_bundle" >&2
    exit 1
  }
  bundle_name=$(basename "$source_bundle")
  destination="$resource_root/$bundle_name"
  rm -rf "$destination"
  /usr/bin/ditto "$source_bundle" "$destination"
  [[ -d "$destination" ]] || {
    echo "Failed to stage SwiftPM resource bundle: $bundle_name" >&2
    exit 1
  }
  printf '%s\n' "$bundle_name" >> "$manifest"
done

paged_resources=("$resource_root"/*.bundle/pagedattention.metal)
(( ${#paged_resources[@]} == 1 )) || {
  echo "Expected exactly one staged pagedattention.metal, found ${#paged_resources[@]}" >&2
  exit 1
}
[[ -s "${paged_resources[0]}" ]] || {
  echo "Staged pagedattention.metal is empty: ${paged_resources[0]}" >&2
  exit 1
}

capability_dir="$resource_root/darkbloom-runtime-capabilities"
mkdir -p "$capability_dir"
printf '1\n' > "$capability_dir/paged-kernel-v1"

LC_ALL=C sort -u "$manifest" -o "$manifest"
echo "Staged ${#bundles[@]} SwiftPM resource bundle(s) in Contents/Resources"
