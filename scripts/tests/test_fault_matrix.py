from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.fault_matrix import (
    FaultMatrixError,
    build_report,
    run_and_build,
    validate_report,
)
from scripts.cutover_readiness.integrity import IntegrityError
from scripts.cutover_readiness.reports import import_fault_matrix_report


class FaultMatrixReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.private = self.root / "receipt.pem"
        self.public = self.root / "receipt.pub.pem"
        subprocess.run(
            [
                "openssl",
                "genpkey",
                "-algorithm",
                "EC",
                "-pkeyopt",
                "ec_paramgen_curve:P-256",
                "-out",
                str(self.private),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.private.chmod(0o600)
        subprocess.run(
            [
                "openssl",
                "pkey",
                "-in",
                str(self.private),
                "-pubout",
                "-out",
                str(self.public),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.receipts = self.root / "receipts"
        self.receipts.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_report_is_rebuilt_only_from_verified_executable_receipts(self) -> None:
        self._write_complete_receipts()
        report = build_report(self.receipts, self.public, expected_commit="a" * 40)
        self.assertEqual(report["boundary_count"], 1)
        self.assertEqual(report["boundaries"][0]["hit_count"], 1)
        self.assertEqual(report["boundaries"][0]["actions"], ["fail"])
        self.assertEqual(report["tested_actions"], ["fail"])
        self.assertEqual(
            validate_report(report, self.public)["boundaries"], report["boundaries"]
        )

    def test_report_declares_only_actions_with_matching_execution_evidence(self) -> None:
        self._write_registry()
        expected = {
            "fail": "failure_returned",
            "delay": "delay_released",
            "crash": "supervisor_panicked",
        }
        for process_id, (action, outcome) in enumerate(expected.items(), start=102):
            receipt = self._receipt()
            receipt["test_id"] = f"postgres_reserve_{action}"
            receipt["process_id"] = process_id
            execution = receipt["hooks"][0]["executions"][0]
            execution["armed_action"] = action
            execution["executed_action"] = action
            execution["outcome"] = outcome
            execution["process_id"] = process_id
            self._write_signed(
                self.receipts / f"receipt-reserve-{action}.json",
                receipt,
            )

        report = build_report(self.receipts, self.public)
        boundary = report["boundaries"][0]
        self.assertEqual(boundary["actions"], ["crash", "delay", "fail"])
        self.assertEqual(report["tested_actions"], ["crash", "delay", "fail"])
        self.assertEqual(
            {
                evidence["action"]: evidence["outcomes"]
                for evidence in boundary["action_evidence"]
            },
            {action: [outcome] for action, outcome in expected.items()},
        )

        report["tested_actions"].append("unobserved")
        with self.assertRaisesRegex(FaultMatrixError, "does not match"):
            validate_report(report, self.public)

    def test_uncovered_registered_boundary_fails_closed(self) -> None:
        self._write_registry()
        with self.assertRaisesRegex(
            FaultMatrixError, "uncovered production fault hook reserve_commit"
        ):
            build_report(self.receipts, self.public)

    def test_tampered_receipt_signature_is_rejected(self) -> None:
        self._write_complete_receipts()
        path = self.receipts / "receipt-reserve.json"
        envelope = json.loads(path.read_text(encoding="utf-8"))
        envelope["signed_payload"] = base64.b64encode(b"{}").decode("ascii")
        path.write_text(json.dumps(envelope), encoding="utf-8")
        with self.assertRaisesRegex(FaultMatrixError, "signature verification failed"):
            build_report(self.receipts, self.public)

    def test_runtime_site_must_match_compiled_registry(self) -> None:
        self._write_registry()
        receipt = self._receipt()
        receipt["hooks"][0]["executions"][0]["site"]["symbol"] = "fake_validator"
        self._write_signed(self.receipts / "receipt-reserve.json", receipt)
        with self.assertRaisesRegex(FaultMatrixError, "does not match registry"):
            build_report(self.receipts, self.public)

    def test_receipt_rejects_missing_or_mismatched_action_and_outcome(self) -> None:
        for mutation in (
            "missing_armed_action",
            "missing_executed_action",
            "missing_outcome",
            "mismatched_action",
            "mismatched_outcome",
        ):
            with self.subTest(mutation=mutation):
                for path in self.receipts.iterdir():
                    path.unlink()
                self._write_registry()
                receipt = self._receipt()
                execution = receipt["hooks"][0]["executions"][0]
                if mutation == "missing_armed_action":
                    del execution["armed_action"]
                elif mutation == "missing_executed_action":
                    del execution["executed_action"]
                elif mutation == "missing_outcome":
                    del execution["outcome"]
                elif mutation == "mismatched_action":
                    execution["executed_action"] = "delay"
                else:
                    execution["outcome"] = "delay_released"
                self._write_signed(self.receipts / "receipt-reserve.json", receipt)
                with self.assertRaisesRegex(FaultMatrixError, "armed action"):
                    build_report(self.receipts, self.public)

    def test_receipt_rejects_execution_from_another_run(self) -> None:
        self._write_registry()
        receipt = self._receipt()
        receipt["hooks"][0]["executions"][0]["run_id"] = "other-run"
        self._write_signed(self.receipts / "receipt-reserve.json", receipt)
        with self.assertRaisesRegex(FaultMatrixError, "run or commit"):
            build_report(self.receipts, self.public)

    def test_cutover_importer_enforces_objective_boundary_count(self) -> None:
        self._write_complete_receipts()
        report = build_report(self.receipts, self.public)
        source = self.root / "fault-matrix.json"
        source.write_text(json.dumps(report), encoding="utf-8")
        with self.assertRaisesRegex(IntegrityError, "boundary count"):
            import_fault_matrix_report(source, trusted_receipt_key=self.public)

    def test_run_requires_signing_key_to_match_configured_trust_anchor(self) -> None:
        other_private = self.root / "other.pem"
        subprocess.run(
            [
                "openssl",
                "genpkey",
                "-algorithm",
                "EC",
                "-pkeyopt",
                "ec_paramgen_curve:P-256",
                "-out",
                str(other_private),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        other_private.chmod(0o600)
        with self.assertRaisesRegex(FaultMatrixError, "does not match"):
            run_and_build(
                ["false"],
                self.root / "must-not-exist.json",
                other_private,
                self.public,
            )
        self.assertFalse((self.root / "must-not-exist.json").exists())

    def test_run_rejects_runtime_write_credentials_and_nonlocal_test_database(self) -> None:
        for environment, message in (
            ({"DATABASE_URL": "postgresql://writer@prod.example/prod"}, "forbidden"),
            (
                {
                    "DARKBLOOM_TEST_DATABASE_URL": (
                        "postgresql://reader@prod.example/test"
                    )
                },
                "loopback",
            ),
        ):
            with mock.patch.dict("os.environ", environment, clear=True):
                with self.assertRaisesRegex(FaultMatrixError, message):
                    run_and_build(
                        ["false"],
                        self.root / "must-not-exist.json",
                        self.private,
                        self.public,
                    )
        self.assertFalse((self.root / "must-not-exist.json").exists())

    def _write_complete_receipts(self) -> None:
        self._write_registry()
        self._write_signed(
            self.receipts / "receipt-reserve.json",
            self._receipt(),
        )

    def _write_registry(self) -> None:
        self._write_signed(
            self.receipts / "instrumentation-registry.json",
            {
                "schema_version": 1,
                "artifact": "fault-instrumentation-registry",
                "objective": 9,
                "run_id": "run-1",
                "commit": "a" * 40,
                "process_id": 101,
                "hooks": [
                    {
                        "id": "reserve_commit",
                        "file": "src/ledger/reserve.rs",
                        "symbol": "LedgerService::reserve",
                        "kind": "async",
                        "guarantees": [
                            "exactly_one_disposition",
                            "no_double_money_mutation",
                        ],
                    }
                ],
            },
        )

    @staticmethod
    def _receipt() -> dict:
        return {
            "schema_version": 1,
            "artifact": "fault-test-receipt",
            "objective": 9,
            "test_id": "postgres_reserve_restart",
            "run_id": "run-1",
            "commit": "a" * 40,
            "process_id": 102,
            "hooks": [
                {
                    "hook_id": "reserve_commit",
                    "hit_count": 1,
                    "executions": [
                        {
                            "hook_id": "reserve_commit",
                            "armed_action": "fail",
                            "executed_action": "fail",
                            "outcome": "failure_returned",
                            "process_id": 102,
                            "run_id": "run-1",
                            "commit": "a" * 40,
                            "site": {
                                "hook_id": "reserve_commit",
                                "file": "crates/server/src/ledger/reserve.rs",
                                "module": "darkbloom_coordinator_server::ledger::reserve",
                                "symbol": "LedgerService::reserve",
                                "line": 422,
                                "kind": "async",
                            },
                        }
                    ],
                }
            ],
            "invariant_assertions": [
                {"id": "exactly_one_disposition", "passed": True},
                {"id": "no_double_money_mutation", "passed": True},
            ],
        }

    def _write_signed(self, path: Path, payload: dict) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        signature = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(self.private)],
            input=encoded,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout
        public_der = subprocess.run(
            [
                "openssl",
                "pkey",
                "-pubin",
                "-in",
                str(self.public),
                "-outform",
                "DER",
            ],
            stdout=subprocess.PIPE,
            check=True,
        ).stdout
        path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "signed_payload": base64.b64encode(encoded).decode("ascii"),
                    "signature": {
                        "algorithm": "openssl-dgst-sha256",
                        "key_id": hashlib.sha256(public_der).hexdigest(),
                        "value": base64.b64encode(signature).decode("ascii"),
                    },
                }
            ),
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
