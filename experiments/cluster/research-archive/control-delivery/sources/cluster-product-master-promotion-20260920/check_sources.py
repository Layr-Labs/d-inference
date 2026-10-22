"""Read-only source/metadata checks; never prepares, compiles, or launches a child."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def require(value, message):
    if not value:
        raise SystemExit(message)


def digest(path):
    require(path.is_file() and not path.is_symlink(), f"Expected regular source: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(name):
    return json.loads((ROOT / name).read_text())


def check(frozen_only=False):
    manifest = read("manifest.json")
    for item in manifest["files"]:
        path = ROOT / item["path"]
        require(digest(path) == item["sha256"] and path.stat().st_size == item["bytes"],
                f"Frozen source changed: {path}")
    integration = read("integration.json")
    target = Path(integration["targetRoot"])
    selection = read("selection.json")
    for item in selection:
        rel = item["path"]
        require(digest(ROOT / "qualified" / rel) == item["qualifiedSHA256"], rel)
        for layer, key in (("main-base", "mainBaseSHA256"), ("target-before", "targetBeforeSHA256")):
            if item[key] is not None:
                require(digest(ROOT / layer / rel) == item[key], f"Retained preimage changed: {rel}")
        if not frozen_only:
            require(digest(Path(item["qualifiedSource"])) == item["qualifiedSHA256"],
                    f"Qualified input changed: {rel}")
    for item in integration["files"]:
        require(digest(ROOT / item["source"]) == item["afterSHA256"], item["path"])
        if not frozen_only:
            path = target / item["path"]
            actual = digest(path) if path.exists() else None
            require(actual == item["beforeSHA256"], f"Target preimage changed: {item['path']}")
    private = read("qualification-integration.json")
    for item in private["files"]:
        require(digest(ROOT / item["source"]) == item["afterSHA256"], item["path"])
        base = ROOT / "proposed" / item["path"]
        expected = digest(base) if base.exists() else None
        require(expected == item["beforeSHA256"], f"Private layer base mismatch: {item['path']}")
    for path in (ROOT / "proposed/provider-swift").rglob("*.swift"):
        value = path.read_text()
        require(not any(x in value for x in ("NATIVE_PAIR_HARDWARE_EXPERIMENT", "DARKBLOOM_PRIVATE", "PrivateClusterTLS")),
                f"Private activation in product: {path}")
        require(not any(line.startswith(("<<<<<<<", "=======", ">>>>>>>")) for line in value.splitlines()),
                f"Unresolved source conflict: {path}")
    coverage = read("test-coverage.json")
    all_labels = coverage["privateQualification"]["completionLabels"]
    product_labels = coverage["defaultProduct"]["completionLabels"]
    require(len(all_labels) == len(set(all_labels)) == 185, "185 exact qualification labels required")
    require(len(product_labels) == len(set(product_labels)) == 181, "181 exact default labels required")
    require(set(all_labels) - set(product_labels) == set(coverage["privateOnlyLabels"]), "Private method split changed")
    original = read("test-source-preservation.json")
    require(len(original["requiredOriginalCompletionLabels"]) == 178, "Original completion contract changed")
    require(set(original["requiredOriginalCompletionLabels"]) <= set(all_labels), "Original control omitted")
    for item in original["sources"]:
        # Some unchanged tests remain in the target, not in this overlay.
        rel = item["path"]
        possibilities = [ROOT / "proposed" / rel, ROOT / "qualification-only" / rel]
        source = next((path for path in possibilities if path.exists()), Path(item["candidateSource"]))
        if not frozen_only or source.is_relative_to(ROOT):
            require(digest(source) == item["qualifiedSHA256"], f"Original test changed: {rel}")
    if not frozen_only:
        for item in read("input-pins.json")["files"]:
            require(digest(Path(item["path"])) == item["sha256"], f"Context changed: {item['path']}")
    return {"sourceChecksPassed": True, "productChangedFiles": integration["changedFiles"],
            "privateQualificationFiles": len(private["files"]), "defaultRequiredCompletions": 181,
            "privateRequiredCompletions": 185, "targetAndExternalInputsChecked": not frozen_only,
            "compilerOrTestsExecuted": False, "workspaceMutated": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--frozen-only", action="store_true", help="check retained source only after target advances")
    args = parser.parse_args()
    print(json.dumps(check(args.frozen_only), sort_keys=True))
