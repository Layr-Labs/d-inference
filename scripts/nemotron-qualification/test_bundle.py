import hashlib
import os
import json
from pathlib import Path
import tempfile
import unittest

from verify_nemotron_bundle import plan, verify_payload

ROOT = Path(__file__).resolve().parent
INDEX = Path(os.environ["NEMOTRON_INDEX"]) if "NEMOTRON_INDEX" in os.environ else None
MANIFEST = ROOT / "weight-manifest.json"


class BundleTests(unittest.TestCase):
    @unittest.skipUnless(INDEX is not None, "set NEMOTRON_INDEX to the downloaded snapshot index")
    def test_official_mtp_is_part_of_single_snapshot(self):
        entries, report = plan(INDEX, MANIFEST)
        self.assertEqual(len(entries), 88)
        self.assertEqual(report["mtp_tensor_count"], 4120)
        self.assertEqual(report["mtp_shards"], ["model-00088-of-00088.safetensors"])
        self.assertFalse(report["payload_verified"])
        self.assertFalse(report["inference_qualified"])

    @unittest.skipUnless(INDEX is not None, "set NEMOTRON_INDEX to the downloaded snapshot index")
    def test_removing_mtp_shard_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = json.loads(MANIFEST.read_bytes())
            reduced = [x for x in manifest if x["path"] != "model-00088-of-00088.safetensors"]
            path = Path(tmp) / "manifest.json"
            path.write_text(json.dumps(reduced))
            with self.assertRaises(ValueError):
                plan(INDEX, path)

    @unittest.skipUnless(INDEX is not None, "set NEMOTRON_INDEX to the downloaded snapshot index")
    def test_rewriting_index_without_mtp_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            index = json.loads(INDEX.read_bytes())
            index["weight_map"] = {k: v for k, v in index["weight_map"].items()
                                   if not k.startswith("language_model.mtp.")}
            path = Path(tmp) / "index.json"
            path.write_text(json.dumps(index))
            with self.assertRaises(ValueError):
                plan(path, MANIFEST)

    def test_payload_corruption_and_missing_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            name = "model.safetensors"
            entries = {name: {"size": 3, "lfs": {"oid": hashlib.sha256(b"abc").hexdigest()}}}
            with self.assertRaises(FileNotFoundError):
                verify_payload(directory, entries)
            (directory / name).write_bytes(b"abc")
            verify_payload(directory, entries)
            (directory / name).write_bytes(b"abd")
            with self.assertRaises(ValueError):
                verify_payload(directory, entries)

    def test_symlink_payload_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "target").write_bytes(b"abc")
            (directory / "model.safetensors").symlink_to("target")
            entries = {"model.safetensors": {"size": 3, "lfs": {"oid": hashlib.sha256(b"abc").hexdigest()}}}
            with self.assertRaises(OSError):
                verify_payload(directory, entries)


if __name__ == "__main__":
    unittest.main()
