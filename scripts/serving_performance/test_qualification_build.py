import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

from .qualification_build import encode_build_record, load_build_record, verified_build_record


def fixture_build_record(source, configuration, binaries, metallibs):
    return {"schema_version": 1, "clean_build": True, "identity_test_passed": True,
            "source": copy.deepcopy(source), "configuration": configuration,
            "test_binaries_sha256": dict(binaries), "metallibs_sha256": dict(metallibs),
            "toolchain": "test Swift compiler", "build_log_sha256": hashlib.sha256(b"build log").hexdigest(),
            "commands": [["swift", "package", "clean"],
                         ["swift", "build", "-c", configuration, "--build-tests", "-Xswiftc", "-enable-testing"],
                         ["stage-test-metallib.sh"], ["swift", "test", "--skip-build"]]}


class QualificationBuildTests(unittest.TestCase):
    def setUp(self):
        self.source = {"head": "a" * 40, "source_tree_sha256": "b" * 64, "dirty": False,
                       "dependency_head": "c" * 40}
        self.binaries = {"test": "d" * 64}
        self.metallibs = {"metal": "e" * 64}
        self.record = fixture_build_record(self.source, "release", self.binaries, self.metallibs)

    def test_stale_release_bundle_cannot_borrow_current_source(self):
        for field in ("head", "source_tree_sha256", "dependency_head"):
            current = dict(self.source, **{field: "f" * len(self.source[field])})
            with self.subTest(field=field), self.assertRaises(ValueError):
                verified_build_record(self.record, current, "release", self.binaries, self.metallibs)

    def test_changed_binary_or_unclean_build_cannot_reuse_record(self):
        for mutation in ("binary", "metal", "clean", "test", "command"):
            record = copy.deepcopy(self.record)
            if mutation == "binary": record["test_binaries_sha256"]["test"] = "f" * 64
            elif mutation == "metal": record["metallibs_sha256"]["metal"] = "f" * 64
            elif mutation == "clean": record["clean_build"] = False
            elif mutation == "test": record["identity_test_passed"] = False
            else: record["commands"][0] = ["swift", "build"]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verified_build_record(record, self.source, "release", self.binaries, self.metallibs)

    def test_raw_build_record_and_command_log_are_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build-receipt.json"
            path.write_bytes(encode_build_record(self.record))
            log = path.with_name("build.log")
            log.write_bytes(b"build log")
            record, digest = load_build_record(path, self.source, "release", self.binaries, self.metallibs)
            self.assertEqual(record, self.record)
            self.assertEqual(digest, hashlib.sha256(path.read_bytes()).hexdigest())
            log.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                load_build_record(path, self.source, "release", self.binaries, self.metallibs)
