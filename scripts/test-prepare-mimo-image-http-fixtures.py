#!/usr/bin/env python3
"""CPU checks for metadata authentication and actual deterministic PNG pixels."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

SPEC = importlib.util.spec_from_file_location(
    "fixtures", Path(__file__).with_name("prepare-mimo-image-http-fixtures.py"))
F = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(F)


class FixtureTests(unittest.TestCase):
    def test_real_pixels_and_chunk_integrity(self):
        for rgb in ((255, 0, 0), (0, 0, 255)):
            data = F.png(rgb)
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            position, kinds = 8, []
            while position < len(data):
                size = struct.unpack(">I", data[position:position + 4])[0]
                kind = data[position + 4:position + 8]
                payload = data[position + 8:position + 8 + size]
                crc = struct.unpack(">I", data[position + 8 + size:position + 12 + size])[0]
                self.assertEqual(crc, zlib.crc32(kind + payload))
                kinds.append(kind)
                if kind == b"IHDR":
                    self.assertEqual(struct.unpack(">IIBBBBB", payload), (28, 28, 8, 2, 0, 0, 0))
                if kind == b"IDAT":
                    self.assertEqual(zlib.decompress(payload), (b"\0" + bytes(rgb) * 28) * 28)
                position += 12 + size
            self.assertEqual(kinds, [b"IHDR", b"IDAT", b"IEND"])
            self.assertEqual(position, len(data))
        self.assertNotEqual(F.png((255, 0, 0)), F.png((0, 0, 255)))

    def test_corrupt_metadata_refuses(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                F.prepare(Path(root) / "fixture", fetch=lambda name: b"corrupt")

    def test_existing_directory_and_dangling_symlink_refuse(self):
        with tempfile.TemporaryDirectory() as root:
            existing = Path(root) / "existing"
            existing.mkdir()
            link = Path(root) / "link"
            link.symlink_to(Path(root) / "absent")
            for path in (existing, link):
                with self.assertRaises(FileExistsError):
                    F.prepare(path, fetch=lambda name: self.fail("must not download"))

    def test_config_matches_closed_candidate_and_no_weight_pins(self):
        root = Path(__file__).resolve().parent.parent
        candidate = (root / "libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/ClusterMiMoImageCandidate.swift").read_text()
        self.assertIn(F.PINS.FILES["config.json"][1], candidate)
        self.assertTrue(all(not name.endswith(".safetensors") for name in F.NAMES))
        self.assertLess(sum(F.PINS.FILES[name][0] for name in F.NAMES), 12 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
