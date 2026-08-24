from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

import assemble_capture


class AssembleCaptureTests(unittest.TestCase):
    def test_assembles_contiguous_chunks_and_hashes_weight(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            chunks = [
                np.arange(12, dtype=np.float32).reshape(3, 4),
                np.arange(8, dtype=np.float32).reshape(2, 4) + 100,
            ]
            for sequence, chunk in enumerate(chunks):
                name = (
                    f"activation-{sequence:04d}-m{chunk.shape[0]}"
                    f"-k{chunk.shape[1]}"
                )
                np.save(directory / f"{name}.npy", chunk)
                (directory / f"{name}.json").write_text(
                    json.dumps(
                        {
                            "sequence": sequence,
                            "source_shape": [1, chunk.shape[0], chunk.shape[1]],
                            "export_shape": list(chunk.shape),
                        }
                    ),
                    encoding="utf-8",
                )

            weight = np.arange(24, dtype=np.float32).reshape(4, 6)
            np.save(directory / assemble_capture.WEIGHT_FILE, weight)
            np.save(directory / "weight-packed.npy", np.arange(4, dtype=np.uint32))
            np.save(directory / "weight-scales.npy", np.ones((1, 1), dtype=np.float32))
            (directory / "weight-manifest.json").write_text(
                json.dumps({"export_shape": [4, 6]}),
                encoding="utf-8",
            )
            output = directory / "activation-8k.npy"
            manifest_path = directory / "capture-manifest.json"

            manifest = assemble_capture.assemble(
                directory,
                output,
                manifest_path,
                expected_rows=5,
                expected_input_width=4,
                expected_output_width=6,
                provenance="unit-test",
            )

            np.testing.assert_array_equal(
                np.load(output), np.concatenate(chunks, axis=0)
            )
            self.assertEqual(manifest["activation"]["shape"], [5, 4])
            self.assertEqual(manifest["weight"]["shape"], [4, 6])
            self.assertEqual(manifest["provenance"], "unit-test")
            self.assertEqual(
                manifest["weight"]["dequantized"]["sha256"],
                assemble_capture.sha256_file(directory / assemble_capture.WEIGHT_FILE),
            )
            self.assertTrue(manifest_path.is_file())


if __name__ == "__main__":
    unittest.main()
