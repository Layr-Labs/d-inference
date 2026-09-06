import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

import run_radix_engine
import unittest

from run_radix_engine import arguments, probe_command


class EngineInvocationTests(unittest.TestCase):
    base = ["--binary", "/binary with spaces", "--model-directory", "/model",
            "--input", "/input.json", "--output", "/evidence"]

    def test_default_remains_compatible_with_archived_serial_binary(self):
        args = arguments(self.base)
        self.assertEqual(probe_command(args, "/result.json"),
                         ["/binary with spaces", "/model", "/input.json", "/result.json",
                          "cache-on", "mtp-off", "auto"])

    def test_concurrent_slot_grant_reaches_binary_after_key_mode(self):
        args = arguments(self.base + ["--concurrency", "4", "--kv-budget-gib", "24",
                                     "--cache-mode", "ssd", "--key-mode", "ephemeral",
                                     "--mtp", "on", "--kv-backend", "paged"])
        self.assertEqual(probe_command(args, "/result.json")[-7:],
                         ["paged", "ssd", "ephemeral-key", "--concurrency", "4",
                          "--kv-budget-gib", "24"])

    def test_invalid_concurrency_or_grant_is_rejected_before_host_work(self):
        for option in (["--concurrency", "0"], ["--concurrency", "8"],
                       ["--kv-budget-gib", "0"], ["--kv-budget-gib", "129"]):
            with self.subTest(option=option), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    arguments(self.base + option)

    def test_production_grant_is_explicit_and_mutually_exclusive(self):
        args = arguments(self.base + ["--production-kv-grant", "--cache-mode", "ssd"])
        self.assertEqual(probe_command(args, "/report.json")[-1], "--production-kv-grant")
        self.assertIsNone(args.kv_budget_gib)  # no fictional 16 GiB in wrapper metadata
        for extra in (["--kv-budget-gib", "16"], ["--cache-mode", "resident"]):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    arguments(self.base + ["--production-kv-grant"] + extra)

    def test_ephemeral_key_requires_explicit_ssd_mode(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            arguments(self.base + ["--key-mode", "ephemeral"])

    def test_gemma_verifier_selection_is_explicit_and_preserves_the_command(self):
        flags = ["--mtp", "on", "--cache", "off", "--cache-mode", "ssd",
                 "--production-kv-grant", "--expected-model-sha256", "a" * 64]
        for backend in ("contiguous", "paged"):
            base = self.base + flags + ["--kv-backend", backend]
            original = probe_command(arguments(base), "/report.json")
            for mode in ("automatic", "serial_target"):
                selected = ["--gemma-mtp-verification", mode]
                self.assertEqual(probe_command(arguments(base + selected), "/report.json"),
                                 original + selected)

    def test_gemma_verifier_refuses_outside_its_diagnostic_scope(self):
        flags = ["--mtp", "on", "--cache", "off", "--cache-mode", "ssd", "--kv-backend", "paged",
                 "--production-kv-grant", "--expected-model-sha256", "a" * 64,
                 "--gemma-mtp-verification", "serial_target"]
        cases = [flags + extra for extra in (["--mtp", "off"], ["--cache", "on"],
            ["--concurrency", "2"], ["--kv-backend", "auto"], ["--cache-mode", "resident"],
            ["--gemma-mtp-verification", "rectangular"], ["--expected-model-sha256", ""])]
        cases.append([x for x in flags if x != "--production-kv-grant"])
        for case in cases:
            with self.subTest(case=case), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    arguments(self.base + case)

    def test_projection_only_adds_the_explicit_pair_to_the_verifier_command(self):
        flags = ["--mtp", "on", "--cache", "off", "--cache-mode", "ssd", "--kv-backend", "paged",
                 "--production-kv-grant", "--expected-model-sha256", "a" * 64,
                 "--gemma-mtp-verification", "automatic"]
        pair = ["--gemma-projection-tokens", "529,62203"]
        self.assertEqual(probe_command(arguments(self.base + flags + pair), "/report.json"),
                         probe_command(arguments(self.base + flags), "/report.json") + pair)
        for raw in ("", "529", "529,62203,7", "-1,3", "1,", "01,3", "1,2147483648", "١,3"):
            with self.subTest(raw=raw), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                arguments(self.base + flags + ["--gemma-projection-tokens", raw])
        for extra in (["--logit-diagnostic-position", "7", "--logit-diagnostic-candidates", "1,2"],
                      ["--attention-metadata-position", "7"],
                      ["--attention-packet-position", "7", "--attention-packet-layer", "0"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                arguments(self.base + flags + pair + extra)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            arguments(self.base + pair)

    def test_diagnostic_only_appends_capture_flags_to_the_same_serving_command(self):
        flags = ["--cache-mode", "ssd", "--key-mode", "ephemeral",
                 "--production-kv-grant", "--expected-model-sha256", "a" * 64]
        diagnostic = ["--logit-diagnostic-position", "62",
                      "--logit-diagnostic-candidates", "1928,6829"]
        for backend in ("contiguous", "paged"):
            for mtp in ("on", "off"):
                with self.subTest(backend=backend, mtp=mtp):
                    base = self.base + flags + ["--kv-backend", backend, "--mtp", mtp]
                    control = probe_command(arguments(base), "/result.json")
                    observed = probe_command(arguments(base + diagnostic), "/result.json")
                    self.assertEqual(observed, control + diagnostic)

    def test_invalid_diagnostic_is_rejected_before_host_work(self):
        valid = ["--logit-diagnostic-position", "53", "--logit-diagnostic-candidates", "1,2"]
        cases = [valid[:2], valid[2:], valid + ["--concurrency", "2"],
                 valid + ["--cache-mode", "resident"]]
        cases += [["--logit-diagnostic-position", position,
                   "--logit-diagnostic-candidates", candidates]
                  for position, candidates in [("-1", "1,2"), ("1000001", "1,2"),
                      ("53", "1,1"), ("53", "1,01"), ("53", "1,2,3"), ("53", "1,"),
                      ("53", "-1"), ("53", "2147483648"), ("53", ""), ("53", "1,x")]]
        for flags in cases:
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    arguments(self.base + ["--cache-mode", "ssd"] + flags)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            arguments(self.base + valid)

    def test_single_candidate_zero_index_is_not_treated_as_disabled(self):
        args = arguments(self.base + ["--cache-mode", "ssd", "--logit-diagnostic-position", "0",
                                      "--logit-diagnostic-candidates", "0"])
        self.assertEqual(probe_command(args, "/result.json")[-4:],
                         ["--logit-diagnostic-position", "0", "--logit-diagnostic-candidates", "0"])

    def test_attention_metadata_preserves_command_and_refuses_unsupported_modes(self):
        flags = ["--cache-mode", "ssd", "--mtp", "off"]
        metadata = ["--attention-metadata-position", "62"]
        for backend in ("contiguous", "paged"):
            base = self.base + flags + ["--kv-backend", backend]
            self.assertEqual(probe_command(arguments(base + metadata), "/result.json"),
                             probe_command(arguments(base), "/result.json") + metadata)
        for extra in (["--mtp", "on"], ["--concurrency", "2"], ["--concurrency", "4"],
                      ["--cache-mode", "resident"]):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    arguments(self.base + flags + metadata + extra)
        for position in ("0", "-1", "1000001", "not-an-integer"):
            with self.subTest(position=position), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    arguments(self.base + flags + ["--attention-metadata-position", position])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            arguments(self.base + metadata)

    def test_combined_metadata_and_logits_preserve_the_same_serving_command(self):
        flags = ["--cache-mode", "ssd", "--key-mode", "ephemeral",
                 "--production-kv-grant", "--mtp", "off", "--expected-model-sha256", "a" * 64]
        metadata = ["--attention-metadata-position", "62"]
        logits = ["--logit-diagnostic-position", "62", "--logit-diagnostic-candidates", "1928,6829"]
        for backend in ("contiguous", "paged"):
            with self.subTest(backend=backend):
                base = self.base + flags + ["--kv-backend", backend]
                control = probe_command(arguments(base), "/result.json")
                self.assertEqual(probe_command(arguments(base + metadata + logits), "/result.json"),
                                 control + logits + metadata)

    def test_packet_flags_coexist_with_independent_metadata_and_logit_positions(self):
        flags = ["--cache-mode", "ssd", "--mtp", "off", "--production-kv-grant"]
        logits = ["--logit-diagnostic-position", "61", "--logit-diagnostic-candidates", "1928,6829"]
        metadata = ["--attention-metadata-position", "62"]
        packet = ["--attention-packet-position", "63", "--attention-packet-layer", "0"]
        for backend in ("contiguous", "paged"):
            with self.subTest(backend=backend):
                base = self.base + flags + ["--kv-backend", backend]
                control = probe_command(arguments(base), "/result.json")
                self.assertEqual(probe_command(arguments(base + packet), "/result.json"), control + packet)
                self.assertEqual(probe_command(arguments(base + packet + metadata + logits), "/result.json"),
                                 control + logits + metadata + packet)

    def test_packet_refuses_partial_invalid_or_unsupported_selection_before_host_work(self):
        base = self.base + ["--cache-mode", "ssd", "--mtp", "off"]
        packet = ["--attention-packet-position", "62", "--attention-packet-layer", "9"]
        invalid = [packet[:2], packet[2:]]
        invalid += [["--attention-packet-position", position, "--attention-packet-layer", layer]
                    for position, layer in (("0", "0"), ("1000001", "0"), ("62", "-1"), ("62", "1024"))]
        invalid += [packet + extra for extra in (["--mtp", "on"], ["--concurrency", "2"],
                                                ["--concurrency", "4"], ["--cache-mode", "resident"])]
        for flags in invalid:
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    arguments(base + flags)

    def test_actual_child_environment_overrides_inherited_key_flags_and_records_isolated_root(self):
        for mode in (None, "persistent", "ephemeral"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary, input_path = root / "probe", root / "input.json"
                binary.write_bytes(b"fixture")
                input_path.write_text("{}")
                args = arguments(["--binary", str(binary), "--model-directory", "/model",
                                  "--input", str(input_path), "--output", str(root / "run"),
                                  "--cache-mode", "ssd"] + (["--key-mode", mode] if mode else []))
                expected = "ephemeral" if mode == "ephemeral" else "persistent"
                captured = []

                def popen(command, **kwargs):
                    if command[0] == str(binary):
                        captured.append(kwargs["env"])
                        Path(command[3]).write_text(json.dumps({"schema": 2,
                            "metrics_loaded": {"key_mode": expected}}))
                    return SimpleNamespace(returncode=0, poll=lambda: 0)

                with patch.object(run_radix_engine, "arguments", return_value=args), \
                     patch.object(run_radix_engine, "ranked_job", return_value=False), \
                     patch.object(run_radix_engine.os, "getloadavg", return_value=(0, 0, 0)), \
                     patch.object(run_radix_engine.subprocess, "run", return_value=SimpleNamespace(returncode=1)), \
                     patch.object(run_radix_engine.subprocess, "check_output", return_value='{"temp":{"gpu_temp_avg":20}}'), \
                     patch.object(run_radix_engine.subprocess, "Popen", side_effect=popen), \
                     patch.dict(run_radix_engine.os.environ, {
                         "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "0",
                         "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "1",
                         "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": "/inherited-shared-root"}):
                    run_radix_engine.main()
                self.assertEqual(len(captured), 1)
                metadata = json.loads((root / "run/metadata.json").read_text())
                self.assertEqual(metadata["status"], "completed")
                actual = captured[0]
                self.assertEqual(actual["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"], str((root / "run/prefix-cache").resolve()))
                self.assertEqual(actual["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"], "1")
                self.assertEqual(actual["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"], "0" if mode == "ephemeral" else "1")
                self.assertEqual(metadata["environment"], {key: actual[key] for key in metadata["environment"]})

    def test_persistent_and_ephemeral_requests_reject_wrong_or_missing_observed_key_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            for requested in ("persistent", "ephemeral"):
                args = arguments(self.base + ["--cache-mode", "ssd", "--key-mode", requested])
                for actual in ("persistent", "ephemeral", None):
                    with self.subTest(requested=requested, actual=actual):
                        report.write_text(json.dumps({"schema": 2, "metrics_loaded": {"key_mode": actual}}))
                        if actual == requested:
                            run_radix_engine.validate_key_mode(args, report)
                        else:
                            with self.assertRaisesRegex(RuntimeError, "Requested " + requested):
                                run_radix_engine.validate_key_mode(args, report)


if __name__ == "__main__":
    unittest.main()
