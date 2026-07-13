from __future__ import annotations

import re
import shlex
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "run-fault-matrix.sh"
SURFACES = (
    ROOT / "Makefile",
    ROOT / ".github" / "workflows" / "ci.yml",
    ROOT / ".github" / "workflows" / "cutover-readiness.yml",
)
EXPECTED_SHARD = [
    "lib:signed_fault_receipts_cover_real_paid_http_postgres_websocket_lifecycle",
    "lib:network_proxy_faults_wrap_real_coordinator_and_provider_peers",
    "lib:child_kill_and_crash_recover_active_paid_request_on_same_lease",
    "integration:fault_injection",
]
INLINE_SHARD_MARKERS = (
    "scripts/fault-matrix.py run",
    "signed_fault_receipts_cover_real_paid_http_postgres_websocket_lifecycle",
    "network_proxy_faults_wrap_real_coordinator_and_provider_peers",
    "child_kill_and_crash_recover_active_paid_request_on_same_lease",
    "--test fault_injection",
)


class FaultWorkflowParityTests(unittest.TestCase):
    def test_canonical_runner_contains_the_complete_evidence_shard(self) -> None:
        completed = subprocess.run(
            [str(RUNNER), "--print-shard"],
            cwd=ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
        self.assertEqual(completed.stdout.splitlines(), EXPECTED_SHARD)

    def test_make_and_workflows_delegate_without_inline_shard_copies(self) -> None:
        invocation = re.compile(
            r"^\s*(?:timeout\s+\d+\s+)?scripts/run-fault-matrix\.sh\s+\\$",
            re.MULTILINE,
        )
        for surface in SURFACES:
            with self.subTest(surface=surface.relative_to(ROOT)):
                source = surface.read_text(encoding="utf-8")
                self.assertEqual(
                    len(invocation.findall(source)),
                    1,
                    f"{surface.relative_to(ROOT)} must invoke the canonical runner once",
                )
                lines = source.splitlines()
                start = next(
                    index
                    for index, line in enumerate(lines)
                    if invocation.fullmatch(line)
                )
                command_lines = [lines[start].strip()]
                while command_lines[-1].endswith("\\"):
                    start += 1
                    command_lines.append(lines[start].strip())
                command = " ".join(
                    line.removesuffix("\\").strip() for line in command_lines
                )
                arguments = shlex.split(command)
                if arguments[0] == "timeout":
                    self.assertGreater(int(arguments[1]), 0)
                    arguments = arguments[2:]
                self.assertEqual(arguments[0], "scripts/run-fault-matrix.sh")
                self.assertEqual(
                    arguments[1::2],
                    ["--output", "--signing-key", "--trusted-key"],
                )
                self.assertEqual(len(arguments), 7)
                for marker in INLINE_SHARD_MARKERS:
                    self.assertNotIn(
                        marker,
                        source,
                        f"{surface.relative_to(ROOT)} duplicates {marker!r}",
                    )

    def test_canonical_runner_is_valid_bash(self) -> None:
        subprocess.run(["bash", "-n", str(RUNNER)], cwd=ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
