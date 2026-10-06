import importlib.util
import contextlib
import io
import os
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

    def test_hf_sources_are_optional_and_commit_pinned(self):
        self.assertIsNone(publisher.hugging_face_artifact(None, None))
        self.assertEqual(publisher.hugging_face_artifact("EigenLabs/model-v2", "b" * 40, "mlx/q4"),
                         {"repo_id": "EigenLabs/model-v2", "revision": "b" * 40, "path_prefix": "mlx/q4"})
        for values in [("EigenLabs/model", "main", None),
                       (None, "b" * 40, None),
                       (None, None, "weights"),
                       ("https://example.test/model", "b" * 40, None),
                       ("EigenLabs/model", "b" * 40, "../weights")]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                publisher.hugging_face_artifact(*values)

    def test_publish_cli_sends_this_revisions_hf_source(self):
        with tempfile.TemporaryDirectory() as scratch:
            def hash_command(args, **kwargs):
                Path(args[args.index("-o") + 1]).write_text(json.dumps(self.manifest))
                return subprocess.CompletedProcess(args, 0)
            arguments = ["publish", scratch, "model", "--version", "v2", "--coordinator", "https://coordinator.test",
                         "--endpoint", "https://r2.test", "--hf-repo-id", "different-owner/new-model",
                         "--hf-revision", "c" * 40, "--hf-path-prefix", "weights/mlx"]
            expected = {"repo_id": "different-owner/new-model", "revision": "c" * 40, "path_prefix": "weights/mlx"}
            with patch.object(publisher.subprocess, "run", side_effect=hash_command), \
                 patch.object(publisher, "reserve_revision", return_value=False), \
                 patch.object(publisher, "publish_files") as upload, \
                 patch.object(publisher.urllib.request, "urlopen") as send, \
                 patch.dict(os.environ, {"MODEL_REGISTRY_PUBLISHING_KEY": "test-publishing-key"}), \
                 contextlib.redirect_stdout(io.StringIO()):
                send.return_value.__enter__.return_value.read.return_value = b'{"status":"promoted"}'
                publisher.main(arguments)
                request = send.call_args.args[0]
                self.assertEqual(json.loads(request.data), {"version": "v2", "hugging_face_artifact": expected})
                upload.assert_not_called()  # an identical published R2 revision is reused
            with patch.object(publisher.subprocess, "run", side_effect=hash_command), \
                 patch.object(publisher, "reserve_revision") as reserve, \
                 patch.object(publisher.urllib.request, "urlopen") as send, \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                publisher.main(arguments + ["--dry-run"])
                self.assertEqual(json.loads(output.getvalue())["hugging_face_artifact"], expected)
                reserve.assert_not_called()
                send.assert_not_called()

    def test_invalid_hf_cli_flags_make_no_local_or_remote_changes(self):
        with tempfile.TemporaryDirectory() as scratch, \
             patch.object(publisher.subprocess, "run") as run, \
             patch.object(publisher.urllib.request, "urlopen") as send, \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as failure:
                publisher.main(["publish", scratch, "model", "--coordinator", "https://coordinator.test",
                                "--endpoint", "https://r2.test", "--hf-repo-id", "EigenLabs/test",
                                "--hf-revision", "main"])
            self.assertEqual(failure.exception.code, 2)
            run.assert_not_called()
            send.assert_not_called()

if __name__ == "__main__":
    unittest.main()
