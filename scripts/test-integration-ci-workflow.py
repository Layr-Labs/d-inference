#!/usr/bin/env python3
"""Offline integration cache wiring and actual build-shell regression tests."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("provider_workflow_tests", ROOT / "scripts/test-provider-ci-workflow.py")
workflow = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workflow)
field, run_command = workflow.field, workflow.run_command
PIN = "1bd1e32a3bdc45362d1e726936510720a7c30a57"


class IntegrationWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / ".github/workflows/integration.yml").read_text()
        self.job = workflow.job_blocks(self.text)["integration-tests"]
        self.steps = workflow.step_blocks(self.job)
        self.named = {field(step, "name", indent=6): step for step in self.steps}
        self.ids = {field(step, "id"): step for step in self.steps if field(step, "id")}

    def test_concurrency_and_job_dependencies(self):
        self.assertIn("  group: ${{ github.workflow }}-${{ github.event_name }}-${{ github.event.pull_request.number || github.run_id }}\n", self.text)
        self.assertIn("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n", self.text)
        self.assertIn("    needs: changes\n", self.job)
        self.assertIn("    runs-on: blacksmith-12vcpu-macos-27\n", self.job)
        self.assertNotIn("continue-on-error:", self.job)

    def test_compatible_restores_and_success_only_saves(self):
        self.assertEqual(run_command(self.ids["keys"]),
                         'python3 scripts/provider-ci-cache.py keys --lane integration >> "$GITHUB_OUTPUT"')
        self.assertLess(self.steps.index(self.named["Prepare source-matched Metal compiler"]),
                        self.steps.index(self.ids["keys"]))
        for kind, outcome in (("swift", "timestamps"), ("rust", "rust-build"), ("metallib", "metallib")):
            restore = self.ids[f"{kind}-cache"]
            self.assertIn(f"actions/cache/restore@{PIN}", restore)
            self.assertIn(f"key: ${{{{ steps.keys.outputs.{kind}-key }}}}", restore)
            if kind == "metallib":
                self.assertNotIn("restore-keys:", restore)
            else:
                self.assertIn(f"restore-keys: ${{{{ steps.keys.outputs.{kind}-prefix }}}}", restore)
            saves = [step for step in self.steps if f"actions/cache/save@{PIN}" in step
                     and f"steps.keys.outputs.{kind}-key" in step]
            self.assertEqual(len(saves), 1)
            self.assertEqual(field(saves[0], "if"),
                             f"${{{{ !cancelled() && steps.{outcome}.outcome == 'success' && steps.{kind}-cache.outputs.cache-hit != 'true' }}}}")
            self.assertEqual(field(restore, "path", 10), field(saves[0], "path", 10))
            self.assertLess(self.steps.index(self.ids[outcome]), self.steps.index(saves[0]))
        for name in ("provider-build", "rust-build", "timestamps", "metallib"):
            self.assertIsNone(field(self.ids[name], "if"))

    def test_compression_tools_are_installed_before_any_cache_restore(self):
        install = self.named["Install Postgres"]
        self.assertEqual(run_command(install), "brew install postgresql@16 zstd")
        self.assertLess(self.steps.index(self.named["Set up Homebrew"]), self.steps.index(install))
        for step in self.steps:
            if "actions/cache/restore@" in step or "actions/setup-go@" in step:
                self.assertLess(self.steps.index(install), self.steps.index(step))

    def test_all_integration_gates_and_flags_remain(self):
        gates = [step for step in self.steps if "go test ./e2e/" in step]
        self.assertEqual(len(gates), 3)
        expected = (
            "go test ./e2e/ -count=1 -v -timeout 25m -p=1 -run 'TestIntegration|TestProfile' -skip '^TestIntegrationExactCacheRouting$'",
            "go test ./e2e/ -count=1 -v -timeout 15m -p=1 -run '^TestIntegrationExactCacheRouting$'",
            "go test ./e2e/ -count=1 -v -timeout 10m -p=1 -run '^TestIntegration_(NonStreaming|Streaming)Inference$'",
        )
        for step, command in zip(gates, expected):
            self.assertIsNone(field(step, "if"))
            normalized = " ".join(run_command(step).replace("\\\n", " ").split())
            self.assertTrue(normalized.endswith(command), normalized)
            self.assertIn('if [ -n "${DARKBLOOM_CBV2_PAGED_KV:-}" ]; then', step)
        for step in gates[:2]:
            self.assertEqual(field(step, "DARKBLOOM_TESTBED_KV_BACKEND", 10), "paged")
            self.assertEqual(field(step, "DARKBLOOM_TESTBED_MAX_CONCURRENT", 10), '"8"')
        self.assertEqual(field(gates[0], "DARKBLOOM_TESTBED_EXPECT_KV_BACKEND", 10), "paged")
        self.assertEqual(field(gates[2], "DARKBLOOM_TESTBED_EXPECT_KV_BACKEND", 10), "contiguous")
        self.assertIsNone(field(gates[2], "DARKBLOOM_TESTBED_KV_BACKEND", 10))

    def test_actual_shell_builds_on_cold_and_warm_cache_and_stages_fresh_metal(self):
        cleanup = self.named["Revalidate source timestamps and discard cached runtime resources"]
        for warm in (False, True):
            with self.subTest(warm=warm), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                scripts = root / "scripts"
                scripts.mkdir()
                shutil.copy(ROOT / "scripts/provider-release-cache.py", scripts)
                shutil.copytree(ROOT / "scripts/provider_release_cache", scripts / "provider_release_cache")
                (root / "provider-swift").mkdir()
                bin_path = root / "provider-swift/.build/arm64-apple-macosx/debug"
                stale = bin_path / "Resources.bundle"
                if warm:
                    stale.mkdir(parents=True)
                    (stale / "mlx.metallib").write_text("stale")
                    (bin_path / "mlx.metallib").write_text("stale")
                tools = root / "tools"
                tools.mkdir()
                fixtures = {
                    "swift": '#!/bin/bash\necho "swift $*" >> "$CALLS"\n'
                             'if [[ "$*" == *--show-bin-path* ]]; then echo "$BIN_PATH"; else mkdir -p "$BIN_PATH"; fi\n',
                    "cargo": '#!/bin/bash\necho "cargo $*" >> "$CALLS"\n',
                    "cmake": '#!/bin/bash\necho "cmake $*" >> "$CALLS"\n',
                }
                for name, body in fixtures.items():
                    path = tools / name
                    path.write_text(body)
                    path.chmod(0o700)
                fetch = scripts / "fetch-metallib.sh"
                fetch.write_text('#!/bin/bash\necho fetch >> "$CALLS"\nprintf matched > "$1/mlx.metallib"\n')
                fetch.chmod(0o700)
                env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                       "CALLS": str(root / "calls"), "BIN_PATH": str(bin_path), "RUNNER_TEMP": str(root)}
                for step in (cleanup, self.ids["provider-build"], self.ids["rust-build"], self.ids["metallib"]):
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", run_command(step)],
                                            cwd=root, env=env, text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    if step == cleanup:
                        self.assertFalse(stale.exists())
                        self.assertFalse((bin_path / "mlx.metallib").exists())
                self.assertEqual((root / "calls").read_text().splitlines(), [
                    "swift build -c debug",
                    "cargo +1.88.0 clean --manifest-path coordinator/promptsidecar/Cargo.toml -p promptsidecar",
                    "cargo +1.88.0 build --manifest-path coordinator/promptsidecar/Cargo.toml --release --locked",
                    "cmake --version", "fetch", "swift build -c debug --show-bin-path",
                ])
                for destination in (root / "provider-swift/.build/debug", bin_path):
                    self.assertEqual((destination / "mlx.metallib").read_text(), "matched")


if __name__ == "__main__":
    unittest.main()
