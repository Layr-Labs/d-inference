"""Bind a cancellation-observer correction to identical measured runtime code."""
import hashlib
import json
from pathlib import PurePosixPath

from .evidence_files import read_evidence
from .matrix import digest
from .qualification_build import verified_build_record

# This narrow exception is for the reviewed observer correction only. A newer
# provider/SDK, arbitrary test change, build flag or supervisor cannot inherit
# old timing evidence simply by presenting matching release version strings.
OBSERVER_FILES = frozenset({
    "provider-swift/Tests/ServingQualificationTests/ServingQualificationLifecycleTests.swift",
    "provider-swift/Tests/ServingQualificationTests/ServingQualificationLifecycleOutcome.swift",
    "provider-swift/Tests/ServingQualificationTests/ServingQualificationLifecycleOutcomeTests.swift",
})


def _manifest(reference, prefix, evidence_root, expected_tree):
    value = json.loads(read_evidence(reference, f"{prefix}_manifest_path",
                                    f"{prefix}_manifest_sha256", evidence_root))
    if not isinstance(value, dict):
        raise ValueError("source manifest must be an object")
    files = value.get("files")
    if (type(value.get("schema_version")) is not int or value["schema_version"] != 1
            or not isinstance(files, dict) or not 1 <= len(files) <= 100_000):
        raise ValueError("source equivalence requires a bounded complete file manifest")
    for name, sha in files.items():
        path = PurePosixPath(name)
        if not name or path.is_absolute() or ".." in path.parts or str(path) != name or not digest(sha):
            raise ValueError("source manifest has an invalid path or file digest")
    actual = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if not digest(expected_tree) or actual != expected_tree:
        raise ValueError("full source manifest differs from the supervised source-tree digest")
    return files


def verify_lifecycle_source_equivalence(reference, provenance, build, *, evidence_root):
    proof = reference.get("source_equivalence")
    if not isinstance(proof, dict):
        raise ValueError("changed lifecycle source/binary requires the reviewed observer-only source proof")
    measured = json.loads(read_evidence(proof, "measured_provenance_path",
                                       "measured_provenance_sha256", evidence_root))
    if not isinstance(measured, dict):
        raise ValueError("measured provenance must be an object")
    source = measured.get("source", {})
    for field, expected in (("head", build["source_commit"]),
                            ("dependency_head", build["sdk_commit"]),
                            ("source_tree_sha256", build["source_tree_sha256"])):
        if source.get(field) != expected:
            raise ValueError("equivalence proof does not reference the actual timing candidate")
    verified_build_record(measured.get("build_record"), source, measured.get("build_configuration"),
                          measured.get("test_binaries_sha256"), measured.get("metallibs_sha256"))
    if build["test_binary_sha256"] not in measured["test_binaries_sha256"].values():
        raise ValueError("equivalence proof does not bind the measured executable")
    current_source = provenance["source"]
    for field in ("dependency_head", "mlx_swift_head", "mlx_head", "mlx_c_head"):
        if (not isinstance(source.get(field), str) or len(source[field]) != 40
                or source[field] != current_source.get(field)):
            raise ValueError("lifecycle observer correction changed a runtime dependency")
    if measured["build_record"].get("toolchain") != provenance["build_record"].get("toolchain"):
        raise ValueError("lifecycle observer correction changed the compiler")
    if measured["build_record"]["commands"][:2] != provenance["build_record"]["commands"][:2]:
        raise ValueError("lifecycle observer correction changed build flags")
    before = _manifest(proof, "measured", evidence_root, build["source_tree_sha256"])
    after = _manifest(proof, "lifecycle", evidence_root, current_source.get("source_tree_sha256"))
    changed = {name for name in before.keys() | after.keys() if before.get(name) != after.get(name)}
    if not changed or not changed <= OBSERVER_FILES:
        raise ValueError("lifecycle evidence changed files outside the reviewed cancellation observer")
    return True
