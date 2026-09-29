import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from .check_receipts import check_errors
from .check_receipt_fixtures import build, references, write
from .matrix import RUNTIME_REVISION


class CheckReceiptTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="prerequisite-files-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.identity = dict(model_id="fixture", artifact_sha256="a" * 64, provider_version="test",
            runtime_revision=RUNTIME_REVISION, kv_backend="paged", configured_context_tokens=262144,
            effective_max_concurrency=4, prefill_chunk_size=1024, max_concurrent_partial_prefills=1,
            solo_prefill_stripe_tokens=4096, mixed_prefill_token_cap=None)
        self.build = build()
        self.checks = references(self.identity, self.build, self.root)

    def errors(self):
        return check_errors(self.checks, self.identity, self.build, evidence_root=self.root)

    def replace_raw(self, check, mutate, provenance=False):
        path_key, hash_key = ("provenance_path", "provenance_sha256") if provenance else ("receipt_path", "receipt_sha256")
        name = self.checks[check][path_key]
        path = self.root / name
        value = json.loads(path.read_bytes())
        mutate(value)
        digest = write(path, value)
        for reference in self.checks.values():
            if reference.get(path_key) == name:
                reference[hash_key] = digest

    def test_real_raw_files_are_hashed_and_scoped(self):
        self.assertEqual(self.errors(), [])
        # Unit evidence intentionally has no model/hardware/provider source
        # requirement: exact SDK and narrow tested scope are its authority.
        self.replace_raw("constraints", lambda raw: raw.update(root_commit="f" * 40, model_id="unit-fixture"))
        self.assertEqual(self.errors(), [])

    def test_shaped_digest_passing_flag_and_missing_file_cannot_pass(self):
        self.checks["constraints"] = {"passed": True, "receipt_sha256": "f" * 64}
        self.assertTrue(self.errors())
        self.checks = references(self.identity, self.build, self.root)
        (self.root / self.checks["retirement"]["receipt_path"]).unlink()
        self.assertTrue(self.errors())

    def test_malformed_and_wrong_hash_are_rejected(self):
        for digest in (None, True, "a" * 63, "A" * 64, "f" * 64):
            with self.subTest(digest=digest):
                self.checks = references(self.identity, self.build, self.root)
                self.checks["constraints"]["receipt_sha256"] = digest
                self.assertTrue(self.errors())
        self.checks = references(self.identity, self.build, self.root)
        self.checks["cancellation"]["provenance_sha256"] = "f" * 64
        self.assertTrue(self.errors())

    def test_rehashed_other_artifact_model_runtime_and_factory_config_do_not_transfer(self):
        for field, replacement in (("modelID", "other"), ("artifactSHA256", "f" * 64),
                                    ("runtimeRevision", "future"), ("providerVersion", "future"),
                                    ("actualKVBackend", "contiguous"), ("mtp", {"enabled": True})):
            with self.subTest(field=field):
                self.checks = references(self.identity, self.build, self.root)
                self.replace_raw("retirement", lambda raw: raw.update({field: replacement}))
                self.assertTrue(self.errors())
        self.checks = references(self.identity, self.build, self.root)
        self.replace_raw("retirement", lambda raw: raw["runtime"].update(effective_max_concurrency=8))
        self.assertTrue(self.errors())

    def test_rehashed_source_sdk_tree_binary_and_metallib_do_not_transfer(self):
        for field, value in (("head", "f" * 40), ("dependency_head", "f" * 40),
                              ("source_tree_sha256", "f" * 64), ("dirty", True)):
            with self.subTest(field=field):
                self.checks = references(self.identity, self.build, self.root)
                self.replace_raw("accounting", lambda raw: raw["source"].update({field: value}), provenance=True)
                self.assertTrue(self.errors())
        self.checks = references(self.identity, self.build, self.root)
        self.replace_raw("accounting", lambda raw: raw["buildIdentity"].update(binarySHA256="f" * 64))
        self.replace_raw("accounting", lambda raw: raw.update(test_binaries_sha256={"other": "f" * 64}), provenance=True)
        self.assertTrue(self.errors())
        self.checks = references(self.identity, self.build, self.root)
        self.replace_raw("accounting", lambda raw: raw.update(metallibs_sha256={"other": "f" * 64}), provenance=True)
        self.assertTrue(self.errors())

    def test_omitted_deadline_cap_and_stripe_are_exact_nil_not_wildcards(self):
        original = copy.deepcopy(self.identity)
        for field, actual in (("mixed_prefill_token_cap", 256), ("solo_prefill_stripe_tokens", 4096)):
            for missing_on in ("candidate", "lifecycle"):
                self.identity = copy.deepcopy(original)
                if missing_on == "candidate": self.identity.pop(field, None)
                else: self.identity[field] = actual
                self.checks = references(self.identity, self.build, self.root)
                self.assertEqual(self.errors(), [])
                if missing_on == "candidate":
                    self.replace_raw("retirement", lambda raw: raw["runtime"].update({field: actual}))
                else:
                    self.replace_raw("retirement", lambda raw: raw["runtime"].pop(field))
                with self.subTest(field=field, missing_on=missing_on):
                    self.assertTrue(self.errors())
    def test_sdk_receipt_cannot_assert_unrun_scope_or_certify_lifecycle(self):
        for mutation in (lambda raw: raw.update(sdk_commit="f" * 40),
                         lambda raw: raw.update(scopes=["constraints"]),
                         lambda raw: raw.update(scopes=["constraints", "isolation", "retirement"]),
                         lambda raw: raw.update(exit_code=1),
                         lambda raw: raw.update(xctest_passed=0, swift_testing_passed=0)):
            self.checks = references(self.identity, self.build, self.root)
            self.replace_raw("constraints", mutation)
            self.assertTrue(self.errors())
        self.checks = references(self.identity, self.build, self.root)
        self.checks["cancellation"] = copy.deepcopy(self.checks["constraints"])
        self.assertTrue(self.errors())

    def test_sdk_missing_or_tampered_log_fails_closed(self):
        self.replace_raw("constraints", lambda raw: raw.pop("log_path"))
        self.assertTrue(self.errors())
        self.checks = references(self.identity, self.build, self.root)
        raw = json.loads((self.root / self.checks["constraints"]["receipt_path"]).read_bytes())
        path = self.root / raw["log_path"]
        original = path.read_bytes()
        path.unlink()
        self.assertTrue(self.errors())
        path.write_bytes(original + b"changed after review\n")
        self.assertTrue(self.errors())

    def test_rehashed_unrelated_or_started_only_log_cannot_certify_scopes(self):
        for mutation in (
                lambda text: text.replace('Suite "CBv2 row-local token constraints" passed',
                                          'Suite "unrelated tests" passed'),
                lambda text: text.replace('Test "finished request id reuse rebuilds fresh constraint state" passed',
                                          'Test "finished request id reuse rebuilds fresh constraint state" started'),
                lambda text: text.replace('Test "auxiliary accounting includes hidden/token history and isolates requests" passed',
                                          'Test "unrelated accounting" passed'),
                lambda text: text.replace('Executed 3 tests, with 0 failures', 'Executed 1 test, with 0 failures'),
                lambda text: text.replace('Test run with 2 tests', 'Test run with 1 test')):
            self.checks = references(self.identity, self.build, self.root)
            raw = json.loads((self.root / self.checks["constraints"]["receipt_path"]).read_bytes())
            path = self.root / raw["log_path"]
            changed = mutation(path.read_text()).encode()
            path.write_bytes(changed)
            self.replace_raw("constraints", lambda value: value.update(log_sha256=hashlib.sha256(changed).hexdigest()))
            self.assertTrue(self.errors())

    def test_missing_real_phase_or_failed_accounting_cannot_be_hidden_by_passed_true(self):
        for mutation in (lambda raw: raw["checks"].pop(),
                         lambda raw: raw["checks"][0].update(reached=False),
                         lambda raw: raw["checks"][0].update(cancelled=False),
                         lambda raw: raw["checks"][0].pop("engineFinishReason"),
                         lambda raw: raw["checks"][0].update(engineFinishReason="stop"),
                         lambda raw: raw["checks"][0].update(retired=False),
                         lambda raw: raw["checks"][0].update(followupParity=False),
                         lambda raw: raw["checks"][0].update(generatedTokensAccounted=3),
                         lambda raw: raw["checks"][0].update(generationRetirements=2)):
            self.checks = references(self.identity, self.build, self.root)
            self.replace_raw("correctness", mutation)
            self.assertTrue(self.errors())

    def test_file_scope_is_explicit_and_no_external_path_is_read(self):
        self.assertTrue(check_errors(self.checks, self.identity, self.build))
        with tempfile.TemporaryDirectory(prefix="external-prerequisite-") as external:
            path = Path(external) / "receipt.json"
            digest = write(path, {"kind": "deterministic_regression"})
            self.checks["constraints"] = {"receipt_path": str(path), "receipt_sha256": digest}
            self.assertTrue(self.errors())
