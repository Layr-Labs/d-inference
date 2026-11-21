#!/usr/bin/env bash
# Report-only coverage of one CI job's own provider test processes. Run from
# provider-swift against the instrumented test products; PROFDATA is the job's
# merged profile. Writes the llvm-cov report, its JSON summary and a summary
# table to OUTPUT and the table to the job's step summary. Each provider test
# job (each shard and Provider Gates) reports its own: they run at the same
# time, so no job sees the others' profiles. The test steps keep their own exit
# codes, so a coverage failure cannot hide or replace a test failure.
#
# Usage: report-provider-coverage.sh PROFDATA OUTPUT
set -euo pipefail
shopt -s nullglob
if [[ $# -ne 2 ]]; then
  echo "usage: $0 PROFDATA OUTPUT" >&2
  exit 2
fi
profdata=$1 out=$2
mkdir -p "$out"
cp "$profdata" "$out/provider.profdata"
bin=$(swift build --show-bin-path)
# The test bundle holds the libraries and the executables the tests
# import; the executables are added so their own code also counts.
bundles=("$bin"/*.xctest)
if [ "${#bundles[@]}" -eq 0 ]; then
  echo "::error::No test bundle in $bin"
  exit 1
fi
binaries=()
for bundle in "${bundles[@]}"; do
  binaries+=("$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
done
for tool in darkbloom darkbloom-fan-helper darkbloom-enclave darkbloom-publish; do
  binaries+=("$bin/$tool")
done
# llvm-cov takes the first binary as an argument, the rest as -object.
args=("${binaries[0]}")
for binary in "${binaries[@]:1}"; do
  args+=(-object "$binary")
done
args+=(-instr-profile "$out/provider.profdata"
  -ignore-filename-regex '/(Tests|\.build|libs)/'
  "$PWD/Sources")
xcrun llvm-cov report "${args[@]}" > "$out/provider-coverage.txt"
tail -n 1 "$out/provider-coverage.txt"
xcrun llvm-cov export -summary-only "${args[@]}" > "$out/provider-coverage.json"
# One row for the code that serves requests (the product), one each
# for the CLI and the benchmark harness, and the total of all files.
# Each value is read by its field name; a missing field or an empty
# row fails the step.
python3 - "$out/provider-coverage.json" "$PWD/Sources" \
  > "$out/provider-coverage-summary.md" <<'PY'
import json
import sys

with open(sys.argv[1]) as export:
    coverage = json.load(export)["data"][0]
source_root = sys.argv[2].rstrip("/") + "/"
product = ["ProviderCore", "ProviderCoreFoundation", "ProviderAppAttest", "DarkbloomFanCore"]
rows = {
    "Provider (Swift) product": product,
    "Provider CLI (`darkbloom`)": ["darkbloom"],
    "Provider benchmark (`ProviderBenchmark`)": ["ProviderBenchmark"],
}
row_by_target = {target: name for name, targets in rows.items() for target in targets}
metrics = ("lines", "regions", "functions")
totals_by_row = {name: {metric: [0, 0] for metric in metrics} for name in rows}
seen_targets = set()
for entry in coverage["files"]:
    target = entry["filename"].removeprefix(source_root).split("/")[0]
    seen_targets.add(target)
    if target not in row_by_target:
        continue
    row_totals = totals_by_row[row_by_target[target]]
    for metric in metrics:
        row_totals[metric][0] += entry["summary"][metric]["covered"]
        row_totals[metric][1] += entry["summary"][metric]["count"]
totals_by_row["Provider (Swift) total"] = {
    metric: [coverage["totals"][metric]["covered"], coverage["totals"][metric]["count"]]
    for metric in metrics
}
print("| Component | Statements or Lines | Regions or Branches | Functions | Target |")
print("|---|---|---|---|---|")
for name, row_totals in totals_by_row.items():
    if row_totals["lines"][1] == 0:
        sys.exit(f"No lines for {name}")
    lines, regions, functions = (
        f"{100 * covered / count:.2f}%"
        for covered, count in (row_totals[metric] for metric in metrics)
    )
    print(f"| {name} | {lines} of {row_totals['lines'][1]:,} lines | {regions} regions | {functions} | 80% (report-only) |")
product_names = [f"`{target}`" for target in product]
other = ", ".join(f"`{target}`" for target in sorted(seen_targets.difference(row_by_target), key=str.lower))
print()
print(f"The product row counts the code that serves requests: {', '.join(product_names[:-1])} and {product_names[-1]}. "
      f"The CLI and the benchmark harness have their own rows. The total counts every file in the report. These targets are only in the total: {other}.")
PY
cat "$out/provider-coverage-summary.md"
{
  cat "$out/provider-coverage-summary.md"
  echo
  echo "Denominator: Swift lines and regions in \`provider-swift/Sources\`, from this job's provider test processes (each provider test job reports its own: Prompt Parity counts in shard 1, the gates in Provider Gates)."
  echo
  echo "Excluded: \`Tests/\`, \`.build/\` (dependencies and generated code), the \`libs/\` checkouts, and the one C++ file in \`ProviderMetallibControl\`, which is not instrumented; Swift has no branch counters, so branches are not reported."
} >> "$GITHUB_STEP_SUMMARY"
