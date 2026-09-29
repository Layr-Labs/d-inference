"""Copy reviewed deadline data into both binaries; never qualify or tune it.

Run from scripts: python3 -m serving_performance.catalog_codegen [--check]
Add only a reviewed evaluator candidate to catalog/deadline_profiles.json first.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("scripts/serving_performance/catalog/deadline_profiles.json")
SWIFT = Path("provider-swift/Sources/ProviderCore/Inference/Performance/Deadline/ReviewedDeadlineProfilesData.swift")
GO = Path("coordinator/registry/deadline_catalog_data.go")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


def canonical_catalog(raw):
    rows = json.loads(raw, object_pairs_hook=_unique_object, parse_constant=_invalid_constant)
    if not isinstance(rows, list):
        raise ValueError("catalog must be an array")
    identifiers = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]:
            raise ValueError("every profile requires a nonempty id")
        if row["id"] in identifiers:
            raise ValueError(f"duplicate profile id: {row['id']}")
        identifiers.add(row["id"])
    # Preserve every reviewed value and array order. This only normalizes JSON
    # whitespace/key ordering; qualification remains a separate reviewed action.
    return json.dumps(rows, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))


def rendered_sources(raw):
    canonical = canonical_catalog(raw)
    checksum = hashlib.sha256(canonical.encode()).hexdigest()
    header = f"// Generated from {SOURCE.as_posix()}; do not edit.\n// Canonical JSON SHA-256: {checksum}\n"
    # Choose a raw-string delimiter that cannot close or interpolate any
    # reviewed string value, even if it contains quotes, backticks or slashes.
    hashes = "#"
    while '"' + hashes in canonical or "\\" + hashes + "(" in canonical:
        hashes += "#"
    swift = header + "enum ReviewedDeadlineProfilesData {\n" + f'    static let json = {hashes}"{canonical}"{hashes}\n' + "}\n"
    go = header + "package registry\n\n" + "const reviewedDeadlineProfilesJSON = " + json.dumps(canonical, ensure_ascii=False) + "\n"
    return {SWIFT: swift, GO: go}


def sync(root=ROOT, check=False):
    outputs = rendered_sources((root / SOURCE).read_bytes())
    mismatches = [str(path) for path, content in outputs.items()
                  if not (root / path).is_file() or (root / path).read_text() != content]
    if check:
        if mismatches:
            raise ValueError("generated deadline catalog differs: " + ", ".join(mismatches))
    else:
        for path, content in outputs.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(content)
    return mismatches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="refuse stale generated sources without writing")
    args = parser.parse_args()
    try:
        sync(check=args.check)
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
