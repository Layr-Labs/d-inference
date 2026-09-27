#!/usr/bin/env bash
# Build/verify the source-matched library, then stage every test runtime layout.
set -euo pipefail
if [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "usage: $0 <existing Swift build bin directory>" >&2
    exit 2
fi
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin_directory=$(cd "$1" && pwd)
"$script_directory/fetch-metallib.sh" "$bin_directory"
test -s "$bin_directory/mlx.metallib"
staging_file=""
trap 'test -z "$staging_file" || rm -f "$staging_file"' EXIT
trap 'exit 143' HUP INT TERM
found=0
for bundle in "$bin_directory"/*PackageTests.xctest; do
    [ -d "$bundle" ] || continue
    for destination in "$bundle/Contents/MacOS/mlx.metallib" \
        "$bundle/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"; do
        directory=$(dirname "$destination")
        mkdir -p "$directory"
        staging_file=$(mktemp "$directory/.mlx-metallib.XXXXXX")
        cp "$bin_directory/mlx.metallib" "$staging_file"
        cmp -s "$bin_directory/mlx.metallib" "$staging_file"
        mv -f "$staging_file" "$destination"
        staging_file=""
    done
    found=1
done
[ "$found" -eq 1 ] || { echo "test runner bundle not found in $bin_directory" >&2; exit 1; }
