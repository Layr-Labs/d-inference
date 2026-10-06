"""Observer-only evidence transfer never excuses a production/build change."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from .check_receipt_fixtures import build, references, write
from .check_receipts import check_errors
from .lifecycle_source import OBSERVER_FILES
from .qualification_build import encode_build_record


def tree(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class LifecycleSourceEquivalenceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="lifecycle-source-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.before = {"provider-swift/Sources/runtime.swift": "1" * 64,
                       "libs/mlx-swift-lm/Libraries/runtime.swift": "2" * 64,
                       "scripts/run-serving-qualification.py": "3" * 64,
                       sorted(OBSERVER_FILES)[0]: "4" * 64}
        self.after = dict(self.before)
        self.after[sorted(OBSERVER_FILES)[0]] = "5" * 64
        self.build = dict(build(), source_tree_sha256=tree(self.before))
        self.identity = dict(model_id="fixture", artifact_sha256="a" * 64, provider_version="test",
            runtime_revision="cbv2-first-content-v2", kv_backend="paged", configured_context_tokens=262144)
        self.checks = references(self.identity, self.build, self.root)
        live = self.checks["cancellation"]
        self.live_path, self.provenance_path = live["receipt_path"], live["provenance_path"]
        self.provenance = json.loads((self.root / self.provenance_path).read_bytes())
        self.provenance["source"].update(mlx_swift_head="1" * 40, mlx_head="2" * 40, mlx_c_head="3" * 40)
        self.provenance["build_record"]["source"] = copy.deepcopy(self.provenance["source"])
        self.provenance["build_record_sha256"] = hashlib.sha256(encode_build_record(self.provenance["build_record"])).hexdigest()
        measured_hash = write(self.root / "measured-provenance.json", self.provenance)
        self.proof = dict(measured_provenance_path="measured-provenance.json",
                          measured_provenance_sha256=measured_hash,
                          measured_manifest_path="before.json", lifecycle_manifest_path="after.json")
        self.proof["measured_manifest_sha256"] = write(self.root / "before.json", dict(schema_version=1, files=self.before))
        self.provenance["source"]["head"] = "f" * 40
        self.provenance["test_binaries_sha256"] = {"fixture.xctest": "f" * 64}
        raw = json.loads((self.root / self.live_path).read_bytes())
        raw["buildIdentity"]["binarySHA256"] = "f" * 64
        sha = write(self.root / self.live_path, raw)
        for reference in self.checks.values():
            if reference.get("receipt_path") == self.live_path:
                reference["receipt_sha256"] = sha
                reference["source_equivalence"] = self.proof
        self.save_source()

    def save_source(self):
        self.proof["lifecycle_manifest_sha256"] = write(self.root / "after.json", dict(schema_version=1, files=self.after))
        self.provenance["source"]["source_tree_sha256"] = tree(self.after)
        record = self.provenance["build_record"]
        record["source"] = copy.deepcopy(self.provenance["source"])
        record["test_binaries_sha256"] = copy.deepcopy(self.provenance["test_binaries_sha256"])
        self.provenance["build_record_sha256"] = hashlib.sha256(encode_build_record(record)).hexdigest()
        sha = write(self.root / self.provenance_path, self.provenance)
        for reference in self.checks.values():
            if reference.get("provenance_path") == self.provenance_path:
                reference["provenance_sha256"] = sha

    def errors(self):
        return check_errors(self.checks, self.identity, self.build, evidence_root=self.root)

    def test_exact_reviewed_observer_change_retains_independent_runtime_identity(self):
        self.assertEqual(self.errors(), [])
        self.proof["lifecycle_manifest_sha256"] = "f" * 64
        self.assertTrue(self.errors())

    def test_production_supervisor_or_unrelated_test_change_cannot_transfer(self):
        original = dict(self.after)
        for name in ("provider-swift/Sources/runtime.swift", "libs/mlx-swift-lm/Libraries/runtime.swift",
                     "scripts/run-serving-qualification.py", "provider-swift/Tests/other.swift", "provider-swift/Package.swift"):
            self.after = dict(original, **{name: "a" * 64})
            self.save_source()
            with self.subTest(name=name):
                self.assertTrue(self.errors())
        self.after = dict(original)
        self.after.pop("provider-swift/Sources/runtime.swift")
        self.save_source()
        self.assertTrue(self.errors())

    def test_changed_compiler_or_dependency_cannot_transfer(self):
        self.provenance["build_record"]["toolchain"] = "different Swift"
        self.save_source()
        self.assertTrue(self.errors())
        self.provenance["build_record"]["toolchain"] = "test Swift compiler"
        self.provenance["source"]["mlx_head"] = "f" * 40
        self.save_source()
        self.assertTrue(self.errors())

    def test_partial_manifest_cannot_replace_the_recorded_full_source_digest(self):
        partial = {name: sha for name, sha in self.before.items() if name in OBSERVER_FILES}
        self.proof["measured_manifest_sha256"] = write(self.root / "before.json", dict(schema_version=1, files=partial))
        self.assertTrue(self.errors())
