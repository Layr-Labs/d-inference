#!/usr/bin/env bash
# The cluster runtime facts (cluster_runtime) of an app bundle, computed by the
# app's own CLI and cluster worker (ClusterRuntimeApprovalFacts).
#
# Usage: provider-cluster-runtime-facts.sh APP CLI_NAME FOLDER
#
# The app lists the models it qualifies on a cluster; their manifest and
# config.json (never weights) come from the public model registry
# (provider-cluster-runtime-models.py); the app's worker describes each one.
# FOLDER must not exist; the facts are FOLDER/cluster-runtime.json and the
# models left out are FOLDER/left-out.md (Markdown lines). The app's
# CLI runs with an empty environment. The release lane and the pull-request
# build both run this script.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 APP CLI_NAME FOLDER" >&2
  exit 64
fi
app=$1
cli=$2
root=$3
scripts=$(cd "$(dirname "$0")" && pwd)

mkdir "$root" "$root/home"
runtime_facts() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$root/home" DARKBLOOM_NO_UPDATE_CHECK=1 \
    "$app/Contents/MacOS/$cli" cluster runtime-facts "$@"
}

runtime_facts --list-release-models > "$root/release-models.json"
python3 "$scripts/provider-cluster-runtime-models.py" \
  --models "$root/release-models.json" --output "$root/candidates"
status=0
runtime_facts --app "$app" --release-candidates "$root/candidates" \
  --require-model Qwen3.5-9B --require-model glm-5.3-flash \
  > "$root/cluster-runtime.json" 2> "$root/runtime-facts.err" || status=$?
# A model the build may leave out (ClusterRuntimeApprovalFacts.softReleaseModels)
# is one line on standard error: a warning annotation, and a line in
# FOLDER/left-out.md for the step summary. Every other line is the command's
# own error output. The command's exit status still decides.
LEFT_OUT='Left out of the cluster runtime facts: '
: > "$root/left-out.md"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "$LEFT_OUT"*)
      printf '::warning::%s\n' "$line"
      printf -- '- **Warning:** %s\n' "$line" >> "$root/left-out.md" ;;
    *) printf '%s\n' "$line" >&2 ;;
  esac
done < "$root/runtime-facts.err"
test "$status" -eq 0
