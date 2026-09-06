import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_radix_engine as runner
from radix_persistent_test_keys import persistent_test_key_provenance


class PersistentTestKeyInvocationTests(unittest.TestCase):
    identifier = "F6AD7F58-BF43-4F6D-A6F2-A9D719E68490"
    group = "TESTTEAM.io.darkbloom.test"
    base = ["--binary", "/binary", "--model-directory", "/model", "--input", "/input",
            "--output", "/tmp/namespace-run", "--cache-mode", "ssd", "--key-mode", "persistent"]

    @property
    def flags(self):
        return ["--persistent-test-namespace", self.identifier, "--persistent-test-access-group", self.group]

    def test_namespace_flags_only_append_the_complete_canonical_selection(self):
        control = runner.probe_command(runner.arguments(self.base), "/report.json")
        args = runner.arguments(self.base + self.flags)
        self.assertEqual(runner.probe_command(args, "/report.json"), control + [
            "--persistent-test-namespace", self.identifier.lower(), "--persistent-test-access-group", self.group])
        proof = persistent_test_key_provenance(args)
        self.assertEqual(proof["namespace"], self.identifier.lower())
        self.assertEqual(proof["access_group"], self.group)
        self.assertEqual(proof["requested_key_mode"], "persistent")
        self.assertEqual(proof["wrapped_kek_account"], "cache-" + self.identifier.lower())
        self.assertNotEqual(proof["enclave_label"], "io.darkbloom.provider.attestation-signing.v2")
        self.assertNotEqual(proof["wrapped_kek_service"], "io.darkbloom.kv.kek.v1")
        self.assertIsNone(persistent_test_key_provenance(runner.arguments(self.base)))

    def test_partial_duplicate_invalid_and_nonpersistent_options_refuse(self):
        invalid = [self.flags[:2], self.flags[2:], self.flags + self.flags[:2], self.flags + self.flags[2:],
                   self.flags + ["--key-mode", "ephemeral"], self.flags + ["--cache-mode", "resident"],
                   ["--persistent-test-namespace", "not-a-uuid", "--persistent-test-access-group", self.group]]
        invalid += [["--persistent-test-namespace", self.identifier, "--persistent-test-access-group", group]
                    for group in ("", "TESTTEAM.*", "TESTTEAM", "TESTTEAM..cache", "TESTTEAM.cache\n")]
        for flags in invalid:
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    runner.arguments(self.base + flags)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            runner.arguments(self.base[:-2] + self.flags)  # no explicit persistent key mode

    def test_namespace_composes_with_both_attention_and_logit_diagnostics(self):
        diagnostic = ["--mtp", "off", "--attention-metadata-position", "62",
                      "--logit-diagnostic-position", "62", "--logit-diagnostic-candidates", "1928,6829",
                      "--attention-packet-position", "62", "--attention-packet-layer", "9"]
        control = runner.probe_command(runner.arguments(self.base + diagnostic), "/report.json")
        selected = runner.probe_command(runner.arguments(self.base + diagnostic + self.flags), "/report.json")
        self.assertEqual(selected, control + ["--persistent-test-namespace", self.identifier.lower(),
                                             "--persistent-test-access-group", self.group])
        self.assertIn("--attention-packet-position", selected)
        self.assertIn("--attention-packet-layer", selected)
        invalid = [diagnostic[:-2] + self.flags, diagnostic + self.flags[:2],
                   diagnostic + self.flags + ["--mtp", "on"],
                   diagnostic + self.flags + ["--key-mode", "ephemeral"]]
        with tempfile.TemporaryDirectory() as tmp:
            for index, mixed in enumerate(invalid):
                output = Path(tmp) / str(index)
                with self.subTest(mixed=mixed), contextlib.redirect_stderr(io.StringIO()), \
                     patch.object(runner.sys, "argv", ["run_radix_engine.py"] + self.base
                                  + ["--output", str(output)] + mixed), \
                     patch.object(runner, "ranked_job") as ranked, \
                     patch.object(runner.subprocess, "run") as host, \
                     patch.object(runner.subprocess, "Popen") as child:
                    with self.assertRaises(SystemExit):
                        runner.main()
                    ranked.assert_not_called()
                    host.assert_not_called()
                    child.assert_not_called()
                    self.assertFalse(output.exists())

    def test_unsafe_root_and_alias_are_refused_before_host_work_or_output_creation(self):
        normal = Path.home() / "Library/Caches/darkbloom/kv3"
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            alias = parent / "normal-alias"
            alias.symlink_to(normal, target_is_directory=True)
            roots = ["", "relative", "/", str(normal), str(normal / "child"),
                     str(normal.parent), str(normal).upper(), str(alias)]
            for index, root in enumerate(roots):
                output = parent / ("attempt-" + str(index))
                argv = self.base + ["--output", str(output), "--cache-directory", root] + self.flags
                with self.subTest(root=root), contextlib.redirect_stderr(io.StringIO()), \
                     patch.object(runner.sys, "argv", ["run_radix_engine.py"] + argv), \
                     patch.object(runner, "ranked_job") as ranked, \
                     patch.object(runner.subprocess, "run") as host, \
                     patch.object(runner.subprocess, "Popen") as child:
                    with self.assertRaises(SystemExit):
                        runner.main()
                    ranked.assert_not_called()
                    host.assert_not_called()
                    child.assert_not_called()
                    self.assertFalse(output.exists())

    def test_actual_child_receives_namespace_root_and_persistent_mode_with_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary, source = root / "fake-probe", root / "input.json"
            binary.write_bytes(b"not executed")
            source.write_text("{}")
            args = runner.arguments(self.base + ["--binary", str(binary), "--input", str(source),
                                    "--output", str(root / "run"), "--cache-directory", str(root / "shared-cache")]
                                    + self.flags)
            expected = persistent_test_key_provenance(args)
            captured = []

            def popen(command, **kwargs):
                if command[0] == str(binary):
                    captured.append((command, kwargs["env"]))
                    Path(command[3]).write_text(json.dumps({"schema": 2, "status": "completed",
                        "metrics_loaded": {"key_mode": "persistent"},
                        "persistent_test_key_namespace": dict(expected, actual_key_mode="persistent")}))
                return SimpleNamespace(returncode=0, poll=lambda: 0)

            with patch.object(runner, "arguments", return_value=args), \
                 patch.object(runner, "ranked_job", return_value=False), \
                 patch.object(runner.os, "getloadavg", return_value=(0, 0, 0)), \
                 patch.object(runner.subprocess, "run", return_value=SimpleNamespace(returncode=1)), \
                 patch.object(runner.subprocess, "check_output", return_value='{"temp":{"gpu_temp_avg":20}}'), \
                 patch.object(runner.subprocess, "Popen", side_effect=popen), \
                 patch.dict(runner.os.environ, {"DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "0",
                     "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "0",
                     "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": "/inherited-root"}):
                runner.main()
            self.assertEqual(len(captured), 1)
            command, environment = captured[0]
            self.assertEqual(command[-4:], ["--persistent-test-namespace", self.identifier.lower(),
                                          "--persistent-test-access-group", self.group])
            self.assertEqual(environment["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"], "1")
            self.assertEqual(environment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"], "1")
            self.assertEqual(environment["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"], expected["isolated_root"])
            metadata = json.loads((root / "run/metadata.json").read_text())
            self.assertEqual(metadata["status"], "completed")
            self.assertEqual(metadata["persistent_test_key_namespace"], dict(expected, actual_key_mode="persistent"))

    def test_success_requires_exact_reported_selectors_root_and_observed_key_mode(self):
        args = runner.arguments(self.base + self.flags)
        expected = persistent_test_key_provenance(args)
        good = {"schema": 2, "metrics_loaded": {"key_mode": "persistent"},
                "persistent_test_key_namespace": dict(expected, actual_key_mode="persistent")}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "report.json"
            path.write_text(json.dumps(good))
            self.assertEqual(runner.validate_key_mode(args, path), good["persistent_test_key_namespace"])
            for field in expected:
                bad = copy.deepcopy(good)
                bad["persistent_test_key_namespace"][field] = "wrong"
                path.write_text(json.dumps(bad))
                with self.subTest(field=field), self.assertRaisesRegex(RuntimeError, "provenance mismatch"):
                    runner.validate_key_mode(args, path)
            for mode in ("ephemeral", None):
                bad = copy.deepcopy(good)
                bad["metrics_loaded"]["key_mode"] = mode
                bad["persistent_test_key_namespace"]["actual_key_mode"] = mode
                path.write_text(json.dumps(bad))
                with self.subTest(mode=mode), self.assertRaisesRegex(RuntimeError, "Requested persistent test key"):
                    runner.validate_key_mode(args, path)
            bad = copy.deepcopy(good)
            del bad["persistent_test_key_namespace"]["actual_key_mode"]
            path.write_text(json.dumps(bad))
            with self.assertRaisesRegex(RuntimeError, "provenance mismatch"):
                runner.validate_key_mode(args, path)
            off = runner.arguments(self.base + self.flags + ["--cache", "off"])
            cold = copy.deepcopy(good)
            cold["metrics_loaded"]["key_mode"] = cold["persistent_test_key_namespace"]["actual_key_mode"] = None
            path.write_text(json.dumps(cold))
            self.assertIsNone(runner.validate_key_mode(off, path)["actual_key_mode"])


if __name__ == "__main__":
    unittest.main()
