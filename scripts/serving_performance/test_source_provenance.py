import json
from pathlib import Path
import tempfile
import unittest

from .source_provenance import source_identity, source_tree_digest


class SourceProvenanceTests(unittest.TestCase):
    def test_portable_receipt_requires_identical_kernel_and_supervisor_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            kernel = root / "libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/gemv.metal"
            kernel.parent.mkdir(parents=True)
            kernel.write_text("kernel original")
            supervisor = root / "scripts/run-serving-qualification.py"
            supervisor.parent.mkdir()
            supervisor.write_text("original supervisor")
            provenance = {"head": "a" * 40, "dirty": False, "source_tree_sha256": source_tree_digest(root)}
            (root / "source-revision.json").write_text(json.dumps(provenance))
            self.assertEqual(source_identity(root), provenance)
            for path in (kernel, supervisor):
                original = path.read_text()
                path.write_text("changed")
                with self.assertRaises(ValueError):
                    source_identity(root)
                path.write_text(original)

    def test_generated_python_cache_is_not_a_source_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            directory = root / "scripts/serving_performance"
            directory.mkdir(parents=True)
            (directory / "source.py").write_text("source")
            before = source_tree_digest(root)
            cache = directory / "__pycache__"
            cache.mkdir()
            (cache / "source.pyc").write_bytes(b"cache")
            self.assertEqual(source_tree_digest(root), before)
