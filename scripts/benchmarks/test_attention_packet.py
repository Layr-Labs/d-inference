import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from attention_packet.__main__ import main
from attention_packet.files import MAX_JSON_BYTES, MAX_TENSOR_BYTES, PacketError, UnsupportedPacket
from attention_packet.native import decode, encode, packed_strides, rounded
from attention_packet.packet import load_packet
from attention_packet.reference import analyze
from attention_packet_fixtures import Fixture


class NativeBytesTests(unittest.TestCase):
    def test_all_native_finite_half_and_bfloat_patterns_promote_exactly(self):
        bits = np.arange(65536, dtype="<u2")
        for dtype, exponent in (("float16", 0x7c00), ("bfloat16", 0x7f80)):
            with self.subTest(dtype=dtype):
                raw = bits.tobytes()
                values = decode(raw, dtype, (1, 1, 1, 65536))
                finite = (bits & exponent) != exponent
                roundtrip = np.frombuffer(encode(values, dtype), dtype="<u2")
                np.testing.assert_array_equal(roundtrip[finite], bits[finite])
                self.assertTrue(np.signbit(values.reshape(-1)[32768]))
                if dtype == "bfloat16":
                    np.testing.assert_array_equal(values.view(np.uint32).reshape(-1), bits.astype(np.uint32) << 16)
                else:
                    special = ((bits.astype(np.uint32) & 0x8000) << 16) | 0x7f800000 | ((bits.astype(np.uint32) & 1023) << 13)
                    np.testing.assert_array_equal(values.view(np.uint32).reshape(-1)[~finite], special[~finite])

    def test_float32_raw_bits_and_bfloat_ties_to_even(self):
        bits = np.array([0, 0x80000000, 1, 0x7f800000, 0xff800000, 0x7fc01234, 0x7f800001], dtype="<u4")
        np.testing.assert_array_equal(decode(bits.tobytes(), "float32", (1, 1, 1, 7)).view(np.uint32).reshape(-1), bits)
        halfway = np.array([0x3f808000, 0x3f818000, 0xbf808000, 0xbf818000], dtype=np.uint32).view(np.float32)
        np.testing.assert_array_equal(np.frombuffer(encode(halfway, "bfloat16"), dtype="<u2"),
                                      [0x3f80, 0x3f82, 0xbf80, 0xbf82])
        tiny_nan = np.array([0x7f800001], dtype=np.uint32).view(np.float32)
        self.assertTrue(np.isnan(rounded(tiny_nan, "bfloat16")[0]))


class PacketValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = Fixture(Path(self.temporary.name) / "packet")

    def test_native_bytes_and_graph_strides_are_not_reinterpreted(self):
        f = self.fixture
        f.record["queries"]["graphConstructionStrides"] = [999, 1, 88, 16]
        packet = load_packet(f.save())
        self.assertEqual(packet.tensors["queries"].raw, (f.root / "queries.bin").read_bytes())
        np.testing.assert_array_equal(packet.tensors["queries"].values, f.values["queries"])
        self.assertEqual(packet.snapshot["expectedOwnerCount"], 1)

    def test_truncated_bytes_wrong_hash_and_metadata_hash_refuse(self):
        f = self.fixture
        for name in ("queries", "storedKeys", "storedValues", "incomingKeys", "incomingValues", "output"):
            path = f.root / f.descriptors[name]["file"]
            original = path.read_bytes()
            path.write_bytes(original[:-1])
            with self.subTest(name=name), self.assertRaisesRegex(PacketError, "length mismatch"):
                load_packet(f.root / "packet.json")
            path.write_bytes(original)
        original = f.descriptors["storedKeys"]["sha256"]
        f.descriptors["storedKeys"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(PacketError, "SHA256 mismatch"):
            load_packet(f.save())
        f.descriptors["storedKeys"]["sha256"] = original
        f.save()
        (f.root / "attention-metadata.json").write_bytes(b" " + (f.root / "attention-metadata.json").read_bytes()[1:])
        with self.assertRaisesRegex(PacketError, "SHA256 mismatch"):
            load_packet(f.root / "packet.json")

    def test_shape_dtype_stride_byteorder_and_missing_tensor_refuse_before_decode(self):
        f = self.fixture
        cases = [("shape", [1, 16, 2, 16]), ("dtype", "float64"), ("packedStrides", [256, 1, 16, 16]),
                 ("byteOrder", "big"), ("byteCount", 1)]
        for field, value in cases:
            previous = copy.deepcopy(f.descriptors["queries"])
            f.descriptors["queries"][field] = value
            with self.subTest(field=field), patch("attention_packet.packet.decode") as decode_spy:
                with self.assertRaises(PacketError):
                    load_packet(f.save())
                decode_spy.assert_not_called()
            f.descriptors["queries"] = previous
        removed = f.descriptors.pop("output")
        with self.assertRaisesRegex(PacketError, "six tensors"):
            load_packet(f.save())
        f.descriptors["output"] = removed

    def test_paths_symlink_aliases_and_duplicate_payloads_refuse(self):
        f = self.fixture
        original = f.descriptors["queries"]["file"]
        outside = Path(self.temporary.name) / "outside.bin"
        outside.write_bytes((f.root / original).read_bytes())
        (f.root / "escape.bin").symlink_to(outside)
        for name in (str(outside), "../outside.bin", "escape.bin", "a/../../outside.bin"):
            f.descriptors["queries"]["file"] = name
            with self.subTest(name=name), self.assertRaisesRegex(PacketError, "escapes"):
                load_packet(f.save())
        f.descriptors["queries"]["file"] = "output.bin"
        with self.assertRaises(PacketError):
            load_packet(f.save())

    def test_json_and_total_native_budget_refuse_before_raw_allocation(self):
        f = self.fixture
        (f.root / "packet.json").write_bytes(b" " * (MAX_JSON_BYTES + 1))
        with self.assertRaisesRegex(PacketError, "byte budget"):
            load_packet(f.root / "packet.json")
        f.save()
        f.descriptors["storedKeys"]["shape"] = [1, 2, MAX_TENSOR_BYTES, 16]
        with patch("attention_packet.packet.decode") as decode_spy:
            with self.assertRaisesRegex(PacketError, "byte budget"):
                load_packet(f.save())
            decode_spy.assert_not_called()
        (f.root / "packet.json").write_text('{"schema":1,"schema":2}')
        with self.assertRaisesRegex(PacketError, "duplicate JSON key"):
            load_packet(f.root / "packet.json")

    def test_aggregate_budget_and_duplicate_files_have_explicit_refusals(self):
        f = self.fixture
        saved = copy.deepcopy(f.descriptors)
        for name in ("storedKeys", "storedValues"):
            f.descriptors[name].update(shape=[1, 2, 4_194_304, 1],
                packedStrides=packed_strides([1, 2, 4_194_304, 1]), byteCount=MAX_TENSOR_BYTES // 2)
        with patch("attention_packet.packet.decode") as decode_spy:
            with self.assertRaisesRegex(PacketError, "total tensor payload exceeds"):
                load_packet(f.save())
            decode_spy.assert_not_called()
        f.descriptors.clear()
        f.descriptors.update(saved)
        f.descriptors["storedValues"]["file"] = f.descriptors["storedKeys"]["file"]
        f.descriptors["storedValues"]["sha256"] = f.descriptors["storedKeys"]["sha256"]
        with self.assertRaisesRegex(PacketError, "duplicate packet payload"):
            load_packet(f.save())

    def test_malformed_json_types_refuse_without_type_crashes(self):
        f = self.fixture
        for target, field in ((f.descriptors["queries"], "dtype"), (f.snapshot, "sampleOutcome"),
                              (f.record, "kernelOutputDType"), (f.document["identity"], "backend")):
            previous = target[field]
            target[field] = []
            with self.subTest(field=field), self.assertRaises(PacketError):
                load_packet(f.save())
            target[field] = previous

    def test_metadata_geometry_and_observed_tensor_mismatches_refuse(self):
        f = self.fixture
        for name, value in (("outputIndex", 61), ("offsetAfter", 17), ("scaleBits", 0x7f800000)):
            previous = f.record[name]
            f.record[name] = value
            with self.subTest(name=name), self.assertRaises(PacketError):
                load_packet(f.save())
            f.record[name] = previous
        f.record["queries"]["dtype"] = "bfloat16"
        with self.assertRaisesRegex(PacketError, "observed queries"):
            load_packet(f.save())

    def test_unsupported_batch_phase_flags_dispatch_are_inconclusive(self):
        f = self.fixture
        for name, value in (("batchSize", 2), ("inputWidth", 2), ("sinksPresent", True),
                            ("softcapPresent", True), ("spansPresent", True),
                            ("phase", "prefill"), ("dispatch", "guessed_backend")):
            previous = f.record[name]
            f.record[name] = value
            with self.subTest(name=name), self.assertRaises(UnsupportedPacket):
                load_packet(f.save())
            f.record[name] = previous
        for flag in ("mtpEnabled", "sharesKV", "isBidirectional"):
            f.document["geometry"][flag] = True
            with self.subTest(flag=flag), self.assertRaises(UnsupportedPacket):
                load_packet(f.save())
            f.document["geometry"][flag] = False

    def test_discarded_or_unconfirmed_step_has_no_reference_or_success_flag(self):
        f = self.fixture
        for outcome in ("discarded", "graph_constructed_unconfirmed", "forward_failed", "retired_unconfirmed"):
            f.snapshot["sampleOutcome"] = outcome
            with patch("attention_packet.reference.attention") as attention_spy:
                report = analyze(load_packet(f.save()))
            self.assertEqual(report["status"], "inconclusive")
            self.assertNotIn("originalQueryReference", report)
            attention_spy.assert_not_called()
            self.assertNotIn("pass", json.dumps(report).lower())

    def test_multiple_duplicate_or_nonzero_owner_selection_is_inconclusive(self):
        f = self.fixture
        second = dict(f.record, storageLayerIndex=1, modelLayerIndex=7)
        cases = [([f.record, second], 2, 0), ([f.record, f.record], 2, 0),
                 ([f.record], 2, 0), ([f.record], 1, 1)]
        for records, expected, index in cases:
            f.snapshot["records"] = records
            f.snapshot["expectedOwnerCount"] = expected
            f.snapshot["configuration"]["maximumRecords"] = 2
            path = f.save()
            f.document["metadata"]["recordIndex"] = index
            path.write_text(json.dumps(f.document))
            with self.subTest(records=len(records), expected=expected, index=index), \
                    patch("attention_packet.packet.decode") as decode_spy:
                with self.assertRaisesRegex(UnsupportedPacket, "exactly one owner"):
                    load_packet(path)
                decode_spy.assert_not_called()
        output = f.root / "multiple-owner.json"
        self.assertEqual(main([str(path), "--output", str(output)]), 2)
        self.assertEqual(json.loads(output.read_text())["status"], "inconclusive")

    def test_cli_writes_exclusive_report_and_preserves_refusals(self):
        f = self.fixture
        output = f.root / "analysis.json"
        self.assertEqual(main([str(f.root / "packet.json"), "--output", str(output)]), 0)
        report = json.loads(output.read_text())
        self.assertEqual(report["status"], "analyzed")
        with self.assertRaises(FileExistsError):
            main([str(f.root / "packet.json"), "--output", str(output)])
        f.record["spansPresent"] = True
        rejected = f.root / "unsupported.json"
        self.assertEqual(main([str(f.save()), "--output", str(rejected)]), 2)
        self.assertEqual(json.loads(rejected.read_text())["status"], "inconclusive")
