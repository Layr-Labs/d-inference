import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("chunk_model", Path(__file__).with_name("chunk-model.py"))
chunk_model = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chunk_model)


class ChunkModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model = self.root / "model"
        self.model.mkdir()
        self.originals = {"nested/model.safetensors": bytes(range(251)) * 17,
                          "config.json": b"{}", "empty.txt": b""}
        files = []
        for name, data in self.originals.items():
            path = self.model / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            files.append({"path": name, "size_bytes": len(data),
                          "sha256": hashlib.sha256(data).hexdigest(), "role": "weight"})
        self.manifest = {"schema_version": 1, "files": files, "file_count": len(files),
                         "total_size_bytes": sum(map(len, self.originals.values())),
                         "aggregate_sha256": hashlib.sha256(b"".join(
                             bytes.fromhex(x["sha256"]) for x in sorted(files, key=lambda x: x["path"])
                         )).hexdigest()}
        self.manifest_path = self.root / "source-manifest.json"
        self.manifest_path.write_text(json.dumps(self.manifest))

    def package(self, size=1000):
        return chunk_model.package_model(self.manifest_path, self.model, self.root / "output", size)

    def test_roundtrip_and_original_hashes(self):
        result = self.package()
        self.assertEqual(result["aggregate_sha256"], self.manifest["aggregate_sha256"])
        for item in result["files"]:
            if "r2_chunks" in item:
                rebuilt = b""
                for i, chunk in enumerate(item["r2_chunks"]):
                    data = (self.root / "output" / f"{item['path']}.chunks/{i:06d}.bin").read_bytes()
                    self.assertEqual(len(data), chunk["size_bytes"])
                    self.assertLessEqual(len(data), 1000)
                    self.assertEqual(hashlib.sha256(data).hexdigest(), chunk["sha256"])
                    rebuilt += data
                self.assertFalse((self.root / "output" / item["path"]).exists())
            else:
                rebuilt = (self.root / "output" / item["path"]).read_bytes()
            self.assertEqual(rebuilt, self.originals[item["path"]])
            self.assertEqual(hashlib.sha256(rebuilt).hexdigest(), item["sha256"])
        self.assertEqual(json.loads(self.manifest_path.read_text()), self.manifest)

    def test_rejects_500mb(self):
        with self.assertRaises(ValueError):
            self.package(500_000_000)

    def test_corrupt_source_never_publishes_manifest(self):
        (self.model / "config.json").write_bytes(b"[]")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.package()
        self.assertFalse((self.root / "output/manifest.json").exists())

    def test_path_traversal(self):
        self.manifest["files"][0]["path"] = "../outside"
        self.manifest_path.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "invalid model path"):
            self.package()

    def test_refuses_existing_output(self):
        self.package()
        with self.assertRaises(FileExistsError):
            self.package()


if __name__ == "__main__":
    unittest.main()
