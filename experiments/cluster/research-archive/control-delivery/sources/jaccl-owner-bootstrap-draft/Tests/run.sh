#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/jaccl-bootstrap.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -pthread \
 -I "$task_root/proposed/libs/mlx-swift/Source/Cmlx/mlx-c/mlx/c/private" \
 "$task_root/Tests/BootstrapStateCheck.cpp" -o "$task_build/check"
"$task_build/check"
