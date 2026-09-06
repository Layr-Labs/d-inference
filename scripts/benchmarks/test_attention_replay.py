import copy
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

import numpy as np

from attention_packet.files import PacketError, sha256
from attention_packet_fixtures import Fixture, write_json
from attention_replay.__main__ import main
from attention_replay.report import collect
from attention_replay.transfer import ARMS, DISPATCH, prepare


class AttentionReplayTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = Fixture(self.root / "packet", dimension=64, length=17)

    def stage(self):
        return prepare(self.fixture.save(), self.root / "replay")

    def fake_results(self, packet, transfer, transfer_hash):
        """Collector fixtures only: these bytes are never claimed as native execution."""
        for arm in ARMS:
            root = self.root / "replay" / arm
            root.mkdir()
            names = ["output"] if arm == "nativeSDPA" else ["output", "storedKeys", "storedValues"]
            tensors = {}
            for name in names:
                tensor = packet.tensors[name]
                tensors[name] = {**tensor.descriptor, "file": name + ".bin"}
                (root / (name + ".bin")).write_bytes(tensor.raw)
            write_json(root / "result.json", {"schema": "darkbloom.attention-replay-result.v1",
                "inputSHA256": transfer_hash, "arm": arm, "dispatch": DISPATCH[arm],
                "kernelOutputDType": packet.tensors["queries" if arm == "nativeSDPA" else "storedKeys"].descriptor["dtype"],
                "segmentCount": 1 if arm == "pagedSegmented" else 0,
                "pageTable": [] if arm == "nativeSDPA" else list(range(1, (packet.record["offsetAfter"] + 15) // 16 + 1)),
                "partitionTokens": None if arm == "nativeSDPA" else 64,
                "geometry": transfer["geometry"], "offset": packet.record["offsetAfter"], "tensors": tensors})

    def test_stages_exact_native_bytes_and_original_confirmed_identity(self):
        packet, transfer, digest = self.stage()
        self.assertEqual(digest, sha256((self.root / "replay/input.json").read_bytes()))
        self.assertEqual(transfer["sampleOutcome"], "confirmed")
        self.assertEqual(transfer["selection"]["phase"], "chained_decode")
        self.assertEqual(transfer["scaleBits"], packet.record["scaleBits"])
        for name, tensor in packet.tensors.items():
            self.assertEqual((self.root / "replay" / (name + ".bin")).read_bytes(), tensor.raw)
        with self.assertRaises(FileExistsError): self.stage()

    def test_unconfirmed_and_unsupported_inputs_refuse_before_output_creation(self):
        self.fixture.snapshot["sampleOutcome"] = "discarded"
        with self.assertRaisesRegex(PacketError, "confirmed"): self.stage()
        self.assertFalse((self.root / "replay").exists())
        self.fixture = Fixture(self.root / "tiny", dimension=16)
        with self.assertRaisesRegex(PacketError, "unsupported paged"): self.stage()
        self.assertFalse((self.root / "replay").exists())

    def test_changed_incoming_tail_refuses_before_gpu_or_output_creation(self):
        f = self.fixture
        f.set_tensor("incomingValues", f.values["incomingValues"] + 1)
        with self.assertRaisesRegex(PacketError, "tail differs"): self.stage()
        self.assertFalse((self.root / "replay").exists())

    def test_nonfinite_and_wrong_input_hash_refuse(self):
        f = self.fixture
        f.set_tensor("queries", np.full_like(f.values["queries"], np.inf))
        with self.assertRaisesRegex(PacketError, "nonfinite"): self.stage()
        f = Fixture(self.root / "second", dimension=64)
        self.fixture = f
        path = f.root / "queries.bin"
        raw = path.read_bytes(); path.write_bytes(raw[:-1])
        with self.assertRaisesRegex(PacketError, "length mismatch"): self.stage()

    def test_prepare_only_cannot_launch_or_select_a_probe(self):
        with patch("attention_replay.__main__.subprocess.run") as runner:
            self.assertEqual(main(["--packet", str(self.fixture.save()), "--output", str(self.root / "stage"),
                                   "--prepare-only"]), 0)
            runner.assert_not_called()
            with self.assertRaisesRegex(PacketError, "explicitly selected"):
                main(["--packet", str(self.fixture.save()), "--output", str(self.root / "unused")])
            self.assertFalse((self.root / "unused").exists())

    def test_same_input_report_preserves_primary_and_counterfactual_without_gate(self):
        packet, transfer, digest = self.stage(); self.fake_results(packet, transfer, digest)
        report = collect(packet, transfer, digest, self.root / "replay")
        self.assertEqual(report["status"], "analyzed")
        self.assertEqual(len(report["sameInputOperatorComparisons"]), 3)
        for entry in report["arms"].values():
            self.assertIn("originalQueryReference", entry)
            self.assertIn("narrowedQueryCounterfactual", entry)
            self.assertNotIn("pass", entry)

    def test_wrong_dispatch_and_input_binding_refuse(self):
        packet, transfer, digest = self.stage(); self.fake_results(packet, transfer, digest)
        path = self.root / "replay/pagedFixed/result.json"
        original = json.loads(path.read_text())
        for key, value in [("dispatch", "paged_segmented_decode"), ("inputSHA256", "c" * 64)]:
            changed = copy.deepcopy(original); changed[key] = value; write_json(path, changed)
            with self.assertRaises(PacketError): collect(packet, transfer, digest, self.root / "replay")
        write_json(path, original)

    def test_planted_head_map_and_dropped_tail_readbacks_are_inconclusive(self):
        packet, transfer, digest = self.stage(); self.fake_results(packet, transfer, digest)
        root = self.root / "replay/pagedFixed"
        path = root / "result.json"
        original = json.loads(path.read_text())
        source = np.frombuffer(packet.tensors["storedValues"].raw, dtype="<u2").reshape(
            packet.tensors["storedValues"].descriptor["shape"])
        for changed in [source[:, ::-1, :, :].copy(), source.copy()]:
            if np.array_equal(changed, source): changed[:, :, -1, :] = 0
            raw = changed.tobytes(); (root / "storedValues.bin").write_bytes(raw)
            receipt = copy.deepcopy(original); receipt["tensors"]["storedValues"]["sha256"] = sha256(raw)
            write_json(path, receipt)
            report = collect(packet, transfer, digest, self.root / "replay")
            self.assertEqual(report["status"], "inconclusive")
            self.assertFalse(report["arms"]["pagedFixed"]["storedHistoryByteIdentity"]["storedValues"])

    def test_truncated_result_wrong_hash_and_transposed_shape_refuse(self):
        packet, transfer, digest = self.stage(); self.fake_results(packet, transfer, digest)
        root = self.root / "replay/nativeSDPA"; path = root / "result.json"
        original = json.loads(path.read_text()); raw = (root / "output.bin").read_bytes()
        (root / "output.bin").write_bytes(raw[:-1])
        with self.assertRaises(PacketError): collect(packet, transfer, digest, self.root / "replay")
        (root / "output.bin").write_bytes(raw)
        for mutate in [lambda d: d.update(sha256="d" * 64),
                       lambda d: d.update(shape=[1, 64, 1, 16], packedStrides=[1024, 16, 16, 1])]:
            receipt = copy.deepcopy(original); mutate(receipt["tensors"]["output"]); write_json(path, receipt)
            with self.assertRaises(PacketError): collect(packet, transfer, digest, self.root / "replay")

    def test_original_backend_reproduction_failure_remains_inconclusive(self):
        packet, transfer, digest = self.stage(); self.fake_results(packet, transfer, digest)
        root = self.root / "replay/pagedSegmented"; path = root / "result.json"
        receipt = json.loads(path.read_text()); raw = bytearray((root / "output.bin").read_bytes())
        raw[0] ^= 1; (root / "output.bin").write_bytes(raw)
        receipt["tensors"]["output"]["sha256"] = sha256(raw); write_json(path, receipt)
        report = collect(packet, transfer, digest, self.root / "replay")
        self.assertEqual(report["status"], "inconclusive")
        self.assertTrue(any("does not reproduce" in reason for reason in report["inconclusiveReasons"]))

    def test_result_symlink_escape_and_alias_page_map_refuse(self):
        packet, transfer, digest = self.stage(); self.fake_results(packet, transfer, digest)
        path = self.root / "replay/pagedFixed/result.json"
        original = json.loads(path.read_text())
        outside = self.root / "external-result.json"
        path.rename(outside); path.symlink_to(outside)
        with self.assertRaisesRegex(PacketError, "symlink escapes"):
            collect(packet, transfer, digest, self.root / "replay")
        path.unlink(); outside.rename(path)
        for field, value in [("pageTable", [1, 1]), ("segmentCount", 1),
                             ("partitionTokens", 32), ("kernelOutputDType", "float32")]:
            changed = copy.deepcopy(original); changed[field] = value; write_json(path, changed)
            with self.assertRaises(PacketError): collect(packet, transfer, digest, self.root / "replay")

    def test_failed_or_timed_out_arm_preserves_evidence_and_stops(self):
        binary = self.root / "probe"; binary.write_bytes(b"not executed")
        for index, effect in enumerate([subprocess.TimeoutExpired([str(binary)], 180), OSError("fixture refusal")]):
            output = self.root / ("failed-" + str(index))
            with patch("attention_replay.__main__.subprocess.run", side_effect=effect) as runner:
                with self.assertRaisesRegex(PacketError, "arm failed"):
                    main(["--packet", str(self.fixture.save()), "--output", str(output),
                          "--binary", str(binary), "--binary-sha256", sha256(binary.read_bytes())])
                self.assertEqual(runner.call_count, 1)
            execution = json.loads((output / "execution.json").read_text())
            self.assertEqual(len(execution), 1)
            self.assertIsNone(execution[0]["exitCode"])
            self.assertIn(type(effect).__name__, execution[0]["failure"])
            self.assertFalse((output / "analysis.json").exists())

    def test_failure_logs_stream_without_read_bytes_and_hash_errors_keep_receipts(self):
        binary = self.root / "probe"; binary.write_bytes(b"not executed")
        original_read = Path.read_bytes
        def bounded_read(path):
            if path.suffix == ".log": raise AssertionError("unbounded log read")
            return original_read(path)
        def failed_run(command, stdout, **kwargs):
            for _ in range(4096): stdout.write("fixture log\n" * 128)
            raise subprocess.TimeoutExpired(command, 180)
        output = self.root / "streamed-failure"
        argv = ["--packet", str(self.fixture.save()), "--output", str(output),
                "--binary", str(binary), "--binary-sha256", sha256(binary.read_bytes())]
        with patch.object(Path, "read_bytes", bounded_read), \
             patch("attention_replay.__main__.subprocess.run", side_effect=failed_run):
            with self.assertRaisesRegex(PacketError, "arm failed"): main(argv)
        record = json.loads((output / "execution.json").read_text())[0]
        self.assertEqual(record["logSHA256"], sha256(original_read(output / "nativeSDPA.log")))
        self.assertIsNone(record["logHashError"])
        output = self.root / "hash-failure"; argv[3] = str(output)
        def fail_hash(path):
            retained = json.loads((output / "execution.json").read_text())[0]
            self.assertIn("TimeoutExpired", retained["failure"])
            self.assertIsNone(retained["logSHA256"])
            raise OSError("fixture unreadable log")
        with patch("attention_replay.__main__.subprocess.run", side_effect=failed_run), \
             patch("attention_replay.__main__.log_sha256", side_effect=fail_hash):
            with self.assertRaisesRegex(PacketError, "arm failed"): main(argv)
        record = json.loads((output / "execution.json").read_text())[0]
        self.assertIn("TimeoutExpired", record["failure"])
        self.assertIn("unreadable log", record["logHashError"])
        self.assertFalse((output / "analysis.json").exists())


if __name__ == "__main__": unittest.main()
