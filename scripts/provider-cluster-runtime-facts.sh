#!/usr/bin/env bash
# The cluster runtime facts (cluster_runtime) of an app bundle for one
# environment, computed by the app's own CLI and cluster worker
# (ClusterRuntimeApprovalFacts), so each model's pair-serving grant and the
# parity qualifications of the models it declares public are that build's
# (its qualification records and ClusterPublicModels).
#
# Usage: provider-cluster-runtime-facts.sh APP CLI_NAME ENVIRONMENT FOLDER
#
# The app lists the models it qualifies on a cluster; their manifest,
# config.json (never weights) and catalog entry (its input modalities) come from
# ENVIRONMENT's public catalog and model CDN (provider-cluster-runtime-models.py),
# which leaves out a listed model that catalog does not have and names it in
# FOLDER/skipped.md; the app's worker describes each one. FOLDER must not exist; the facts are
# FOLDER/cluster-runtime.json. The app's CLI runs with an empty environment.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 APP CLI_NAME ENVIRONMENT FOLDER" >&2
  exit 64
fi
app=$1
cli=$2
environment=$3
root=$4
scripts=$(cd "$(dirname "$0")" && pwd)

mkdir "$root" "$root/home"
runtime_facts() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$root/home" DARKBLOOM_NO_UPDATE_CHECK=1 \
    "$app/Contents/MacOS/$cli" cluster runtime-facts "$@"
}

runtime_facts --list-release-models > "$root/release-models.json"
python3 "$scripts/provider-cluster-runtime-models.py" --environment "$environment" \
  --models "$root/release-models.json" --output "$root/candidates" --skipped "$root/skipped.md"
runtime_facts --app "$app" --release-candidates "$root/candidates" > "$root/cluster-runtime.json"
