"""CPU-only validation/build regressions; no model, GPU or archived binary needed."""

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import warnings
import zipfile
import zlib

spec = importlib.util.spec_from_file_location("native_kv_replay", Path(__file__).with_name("run.py"))
replay = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = replay
spec.loader.exec_module(replay)


def encoded(value):
    return json.dumps(value).encode()


class ReplayValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.members = {}
        records = []
        for name, role, data in [("K.bin", "keys", b"1234"), ("V.bin", "values", b"5678"),
                                 ("Gamma.bin", "gamma", b"abcd")]:
            self.members["gemma/" + name] = data
            records.append(dict(file=name, role=role, bytes=len(data), dtype="bfloat16", shape=[2],
                sha256=hashlib.sha256(data).hexdigest(), phase="prefill", position=1, layer=0))
        self.receipt = dict(model_aggregate_sha256="0" * 64, config_sha256="1" * 64,
                            sdk_revision="abcdef0-dirty", records=records, copied_native_payload_bytes=12)
        self.members["gemma/receipt.json"] = encoded(self.receipt)
        self.members["gemma/model-manifest.json"] = encoded(dict(aggregate_sha256="0" * 64,
            files=[dict(path="config.json", sha256="1" * 64)]))

    def specs(self):
        return replay.input_specs([dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                                   for name, data in self.members.items()])

    def archive(self, entries=None, symlink=None):
        path = self.root / "inputs.zip"
        with warnings.catch_warnings(), zipfile.ZipFile(path, "w") as bundle:
            warnings.simplefilter("ignore", UserWarning)
            for name, data in entries if entries is not None else self.members.items():
                if name == symlink:
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    bundle.writestr(info, data)
                else:
                    bundle.writestr(name, data)
        return path

    def unpack(self):
        destination = self.root / "extracted"
        replay.unpack_inputs(self.archive(), self.specs(), destination)
        return destination

    def test_all_records_verified_but_only_kv_selected(self):
        destination = self.unpack()
        packets, provenance = replay.read_packets(destination, self.specs(), "abcdef0123456789")
        self.assertEqual([packet.record["role"] for packet in packets], ["keys", "values"])
        self.assertEqual(provenance["gemma"]["verifiedNativeRecords"], 3)
        self.assertEqual(provenance["gemma"]["verifiedGammaRecords"], 1)
        self.assertEqual((destination / "gemma/Gamma.bin").read_bytes(), b"abcd")

    def test_gamma_hash_failure_is_not_skipped(self):
        specs = self.specs()
        self.members["gemma/Gamma.bin"] = b"evil"
        with self.assertRaisesRegex(replay.EvidenceError, "SHA-256"):
            replay.unpack_inputs(self.archive(), specs, self.root / "extracted")

    def test_extra_missing_duplicate_and_symlink_members_rejected(self):
        entries = list(self.members.items())
        cases = [(entries + [("extra.bin", b"x")], None), (entries[:-1], None),
                 (entries + entries[:1], None), (entries, "gemma/Gamma.bin")]
        for index, (members, symlink) in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(replay.EvidenceError):
                replay.unpack_inputs(self.archive(members, symlink), self.specs(), self.root / f"out-{index}")

    def test_noncanonical_paths_and_duplicate_manifest_rows_rejected(self):
        for name in ("../escape", "/absolute", "gemma/../escape", "gemma//K.bin", "gemma\\K.bin", "C:/escape"):
            with self.subTest(name=name), self.assertRaises(replay.EvidenceError):
                replay.relative_name(name)
        item = dict(path="gemma/K.bin", bytes=4, sha256="0" * 64)
        with self.assertRaises(replay.EvidenceError):
            replay.input_specs([item, item])

    def test_internally_inconsistent_receipts_rejected(self):
        self.receipt["records"][0]["sha256"] = "f" * 64
        self.members["gemma/receipt.json"] = encoded(self.receipt)
        destination = self.unpack()
        with self.assertRaisesRegex(replay.EvidenceError, "receipt/input mismatch"):
            replay.read_packets(destination, self.specs(), "abcdef0123456789")

    def test_model_identity_mismatch_rejected(self):
        self.members["gemma/model-manifest.json"] = encoded(dict(aggregate_sha256="f" * 64))
        destination = self.unpack()
        with self.assertRaisesRegex(replay.EvidenceError, "aggregate mismatch"):
            replay.read_packets(destination, self.specs(), "abcdef0123456789")

    def test_sdk_mismatch_and_truncated_zip_rejected(self):
        destination = self.unpack()
        with self.assertRaisesRegex(replay.EvidenceError, "SDK revision mismatch"):
            replay.read_packets(destination, self.specs(), "123456789abcdef0")
        path = self.root / "truncated.zip"
        path.write_bytes(b"not a ZIP archive")
        with self.assertRaises(zipfile.BadZipFile):
            replay.unpack_inputs(path, self.specs(), self.root / "unused")

    def test_corrupted_deflate_payload_rejected(self):
        data = b"a" * 1024
        path = self.root / "deflated.zip"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
            bundle.writestr("tensor.bin", data)
            member = bundle.getinfo("tensor.bin")
            offset = member.header_offset + 30 + len(member.filename.encode()) + len(member.extra)
        corrupted = bytearray(path.read_bytes())
        corrupted[offset] = 0x07  # Reserved DEFLATE block type.
        path.write_bytes(corrupted)
        specs = {"tensor.bin": (len(data), hashlib.sha256(data).hexdigest())}
        with self.assertRaises((zipfile.BadZipFile, zlib.error)):
            replay.unpack_inputs(path, specs, self.root / "invalid-deflate")

    def test_bad_codec_receipts_rejected(self):
        packet = replay.Packet("gemma", self.receipt["records"][0], "0" * 64)
        valid = dict(schema=replay.PROBE_SCHEMA, bitExact=True, input="K.bin", elementBytes=2,
                     inputSHA256=packet.record["sha256"], nativeBytes=4, encodedFrameBytes=6,
                     savingFraction=-0.5, encodeSeconds=[0.0] * 5, decodeSeconds=[0.0] * 5)
        replay.validate_probe(valid, packet)
        for changes in ({"bitExact": False}, {"nativeBytes": 5}, {"encodedFrameBytes": 7},
                        {"elementBytes": 4}, {"savingFraction": float("nan")},
                        {"encodeSeconds": [float("inf")] * 5}, {"decodeSeconds": []}):
            with self.subTest(changes=changes), self.assertRaises(replay.EvidenceError):
                replay.validate_probe(valid | changes, packet)

    def test_duplicate_json_keys_and_existing_output_rejected(self):
        with self.assertRaises(replay.EvidenceError):
            replay.parse_json('{"bytes": 1, "bytes": 2}', "test")
        with self.assertRaises(replay.EvidenceError):
            replay.parse_json('{"bytes": NaN}', "test")
        with self.assertRaisesRegex(replay.EvidenceError, "must not already exist"):
            replay.replay(SimpleNamespace(output=self.root, codec_binary=Path("missing"), input_archive=Path("missing")))

    def test_probe_diff_checks_uncompressed_member_hash(self):
        diff = b"test package diff"
        path = self.root / "package.zip"
        with zipfile.ZipFile(path, "w") as bundle:
            bundle.writestr("package.diff", diff)
        replay.verify_probe_package(path, hashlib.sha256(diff).hexdigest())
        with self.assertRaises(replay.EvidenceError):
            replay.verify_probe_package(path, "0" * 64)


class CodecPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "caller-source.swift"
        self.source.write_text("enum FixtureCodec {}\n")
        self.driver = b'print("verified fixture built")\n'
        self.manifest = dict(codecSourceSHA256=replay.digest(self.source),
                             driverSHA256=hashlib.sha256(self.driver).hexdigest(), binarySHA256="0" * 64)
        self.args = SimpleNamespace(codec_binary=None, build_codec_source=self.source,
                                    codec_source=None, build_timeout=30)

    @unittest.skipUnless(Path("/usr/bin/swiftc").is_file(), "fixed Apple Swift compiler unavailable")
    def test_fixed_compiler_builds_verified_copies_and_records_provenance(self):
        binary, provenance = replay.prepare_codec(self.args, self.manifest, self.driver, self.root / "build")
        self.assertEqual(subprocess.check_output([binary], text=True).strip(), "verified fixture built")
        self.assertEqual(provenance["mode"], "verified-source-build")
        self.assertEqual(provenance["binarySHA256"], replay.digest(binary))
        self.assertTrue(provenance["sourceVerified"])
        compiler = provenance["compiler"]
        self.assertEqual(compiler["path"], "/usr/bin/swiftc")
        self.assertEqual(compiler["arguments"], ["-O", "SSDLosslessChunkCodec.swift", "main.swift", "-o", "codec-probe"])
        self.assertIn("Swift", compiler["version"])
        self.assertEqual(compiler["buildTimeoutSeconds"], 30)
        self.assertEqual((binary.parent / "SSDLosslessChunkCodec.swift").read_bytes(), self.source.read_bytes())
        self.assertEqual((binary.parent / "main.swift").read_bytes(), self.driver)

    def test_source_and_driver_mismatches_fail_before_build_directory(self):
        for kind in ("source", "driver"):
            build = self.root / ("bad-" + kind)
            manifest = self.manifest.copy()
            manifest["codecSourceSHA256" if kind == "source" else "driverSHA256"] = "f" * 64
            with self.subTest(kind=kind), self.assertRaisesRegex(replay.EvidenceError, "SHA-256 mismatch"):
                replay.prepare_codec(self.args, manifest, self.driver, build)
            self.assertFalse(build.exists())

    def test_archived_binary_mode_never_accepts_a_different_digest(self):
        binary = self.root / "different-binary"
        binary.write_text("#!/bin/sh\necho fixture\n")
        binary.chmod(0o700)
        args = SimpleNamespace(codec_binary=binary, build_codec_source=None, codec_source=None)
        with self.assertRaisesRegex(replay.EvidenceError, "wrong SHA-256"):
            replay.prepare_codec(args, self.manifest, self.driver, self.root / "unused")
        self.assertFalse((self.root / "unused").exists())
        manifest = self.manifest | dict(binarySHA256=replay.digest(binary))
        selected, provenance = replay.prepare_codec(args, manifest, self.driver, self.root / "unused")
        self.assertEqual(selected, binary.resolve())
        self.assertEqual(provenance["mode"], "archived-binary")
        self.assertIsNone(provenance["compiler"])

    def test_ambiguous_mode_and_invalid_build_timeout_rejected(self):
        self.args.codec_binary = self.source
        with self.assertRaisesRegex(replay.EvidenceError, "exactly one"):
            replay.prepare_codec(self.args, self.manifest, self.driver, self.root / "unused")
        self.args.codec_binary = None
        for timeout in (0, -1, float("inf")):
            self.args.build_timeout = timeout
            with self.subTest(timeout=timeout), self.assertRaisesRegex(replay.EvidenceError, "timeout"):
                replay.prepare_codec(self.args, self.manifest, self.driver, self.root / "unused")

    @unittest.skipUnless(Path("/usr/bin/swiftc").is_file(), "fixed Apple Swift compiler unavailable")
    def test_compiler_failure_is_reported_without_an_executable(self):
        self.source.write_text("this is invalid Swift source\n")
        self.manifest["codecSourceSHA256"] = replay.digest(self.source)
        with self.assertRaisesRegex(replay.EvidenceError, "verified codec build failed"):
            replay.prepare_codec(self.args, self.manifest, self.driver, self.root / "build")
        self.assertFalse((self.root / "build/codec-probe").exists())

    @unittest.skipUnless(Path("/usr/bin/swiftc").is_file(), "fixed Apple Swift compiler unavailable")
    def test_compiler_deadline_fails_without_an_executable(self):
        self.args.build_timeout = 0.000001
        with self.assertRaisesRegex(replay.EvidenceError, "timed out"):
            replay.prepare_codec(self.args, self.manifest, self.driver, self.root / "build")
        self.assertFalse((self.root / "build/codec-probe").exists())


if __name__ == "__main__":
    unittest.main()
