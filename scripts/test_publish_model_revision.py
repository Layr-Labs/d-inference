import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publish_model_revision", Path(__file__).with_name("publish-model-revision.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)

class PublishRevisionTests(unittest.TestCase):
    def setUp(self):
        self.manifest = dict(schema_version=1, model_id="model", version="v2", r2_prefix="v2/model/v2",
                             aggregate_sha256="b" * 64, total_size_bytes=3, file_count=1,
                             files=[dict(path="model.safetensors", sha256="a" * 64, size_bytes=3, role="weight")])

    def test_existing_identical_revision_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as scratch, patch.object(publisher, "read_object", return_value=json.dumps(self.manifest).encode()), patch.object(publisher, "aws") as aws:
            self.assertFalse(publisher.reserve_revision(self.manifest, "bucket", "endpoint", scratch))
            aws.assert_not_called()

    def test_existing_version_with_changed_bytes_is_rejected(self):
        previous = dict(self.manifest, aggregate_sha256="c" * 64)
        with tempfile.TemporaryDirectory() as scratch, patch.object(publisher, "read_object", return_value=json.dumps(previous).encode()), patch.object(publisher, "aws") as aws:
            with self.assertRaises(ValueError):
                publisher.reserve_revision(self.manifest, "bucket", "endpoint", scratch)
            aws.assert_not_called()

    def test_competing_different_reservation_is_rejected(self):
        conflict = subprocess.CompletedProcess([], 1, "", "PreconditionFailed (412)")
        with tempfile.TemporaryDirectory() as scratch, patch.object(publisher, "read_object", side_effect=[None, b"different"]), patch.object(publisher, "aws", return_value=conflict):
            with self.assertRaises(ValueError):
                publisher.reserve_revision(self.manifest, "bucket", "endpoint", scratch)

    def test_manifest_is_uploaded_last(self):
        with tempfile.TemporaryDirectory() as scratch, patch.object(publisher, "aws") as aws:
            publisher.publish_files(Path(scratch), Path(scratch)/"manifest.json", self.manifest, "bucket", "endpoint")
            calls = aws.call_args_list
            self.assertTrue(calls[-1].args[0][3].endswith("/manifest.json"))
            self.assertEqual(len(calls), 2)

    def test_failed_file_never_publishes_manifest(self):
        with tempfile.TemporaryDirectory() as scratch, patch.object(publisher, "aws", side_effect=RuntimeError("network unavailable")) as aws:
            with self.assertRaises(RuntimeError):
                publisher.publish_files(Path(scratch), Path(scratch)/"manifest.json", self.manifest, "bucket", "endpoint")
            self.assertEqual(aws.call_count, 1)

if __name__ == "__main__":
    unittest.main()
