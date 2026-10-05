#!/usr/bin/env python3
"""Offline routing regressions: real Git histories and exact workflow wiring."""

import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("component_paths", ROOT / "scripts/ci-component-paths.py")
routing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routing)
spec = importlib.util.spec_from_file_location("provider_workflow", ROOT / "scripts/test-provider-ci-workflow.py")
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


class ComponentPathsTests(unittest.TestCase):
    def test_instructions_and_docs_never_select_expensive_lanes(self):
        paths = ["AGENTS.md", "docs/AGENTS.md", "docs/developer/test.md",
                 "provider-swift/AGENTS.md", "console-ui/AGENTS.md",
                 "scripts/docs-check.sh", "scripts/test-docs-impact-check.py",
                 "scripts/admin.sh", "landing/src/app/page.tsx"]
        self.assertFalse(any(routing.classify(paths).values()))

    def test_component_and_shared_dependency_matrix(self):
        cases = {
            "provider-swift/Sources/ProviderCore/ProviderCore.swift": {"coordinator", "provider", "integration", "benchmark"},
            "libs/mlx-swift-lm": {"provider", "integration", "benchmark"},
            "libs/mlx-swift": {"provider", "integration", "benchmark"},
            "coordinator/store/postgres/users.go": {"coordinator", "integration", "benchmark"},
            "console-ui/package-lock.json": {"console"},
            "coordinator/protocol/messages.go": {"coordinator", "provider", "sidecar", "integration", "benchmark"},
            "coordinator/tests/protocol/testdata/messages.json": {"coordinator", "provider", "sidecar", "integration", "benchmark"},
            "fixtures/prompt-contract/v1/corpus.json": {"coordinator", "provider", "sidecar", "integration", "benchmark"},
            "coordinator/internal/promptproof/load.go": {"coordinator", "provider", "sidecar", "integration", "benchmark"},
            "coordinator/promptsidecar/Cargo.lock": {"coordinator", "provider", "sidecar", "integration", "benchmark"},
            "go.sum": {"coordinator", "provider", "sidecar", "integration", "benchmark"},
            "scripts/run-coordinator-tests.py": {"coordinator", "integration", "benchmark"},
            "scripts/coordinator-statement-coverage.sh": {"coordinator", "integration", "benchmark"},
            "scripts/install-release-rust.sh": {"provider", "sidecar", "integration", "benchmark"},
            ".github/actions/provider-ci-build/action.yml": {"provider", "integration", "benchmark"},
            ".github/workflows/ci.yml": {"coordinator", "provider", "sidecar", "console"},
            ".github/workflows/integration.yml": {"integration"},
            ".github/workflows/benchmarks.yml": {"benchmark"},
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual({name for name, value in routing.classify([path]).items() if value}, expected)
        for path in routing.COMMON:
            self.assertTrue(all(routing.classify([path]).values()), path)

    def test_rust_embedded_swift_corpora_select_sidecar_only_when_consumed(self):
        for filename in ("nemotron-prompt-edge-corpus.json", "nemotron-reference-corpus.json"):
            path = "provider-swift/Tests/ProviderCoreTests/Fixtures/" + filename
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file(), path)
                selected = routing.classify([path])
                self.assertEqual({name for name, value in selected.items() if value},
                                 {"provider", "sidecar", "integration", "benchmark"})
        unrelated = "provider-swift/Tests/ProviderCoreTests/Fixtures/other-corpus.json"
        self.assertFalse(routing.classify([unrelated])["sidecar"])

    def test_selected_executable_dependencies_are_classified(self):
        # Explicitly pin the executable dependencies, not every scripts/** file.
        for path in (
            "scripts/prepare-provider-release-toolchain.sh", "scripts/install-release-cmake.sh",
            "scripts/prepare-metal-toolchain.py", "scripts/provider-ci-cache.py",
            "scripts/provider_release_cache/mtimes.py", "scripts/fetch-metallib.sh",
            "scripts/stage-test-metallib.sh", "scripts/run-provider-tests.sh",
            "scripts/run-nested-suite.sh", "scripts/run-paged-kernel-tests.sh",
            "scripts/run-exclusive-native-gpu-test.sh",
            "scripts/run-provider-test-watchdog.py", "scripts/prepare-mimo-audio-fixtures.py",
            "scripts/prepare-mimo-provider-fixtures.py", "scripts/prepare-mimo-prompt-fixtures.py",
            "scripts/test-profile-inventory-auth.py", "scripts/test-qwen4-packaged-resources.py",
            "scripts/verify-prompt-parity.sh", "scripts/verify-nemotron-prompt-parity.sh",
            "scripts/install.sh", "scripts/test-install-atomic.sh",
            "coordinator/internal/promptcontract/endpoint/endpoint_lower.go",
            "coordinator/cmd/promptfixtureinput/main.go",
            "coordinator/cmd/promptsidecarloadproof/main.go",
        ):
            self.assertTrue((ROOT / path).is_file(), path)
            self.assertTrue(routing.classify([path])["provider"], path)


class GitDiffTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ci-component-git-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.git("init", "-b", "master")
        self.git("config", "user.name", "CI Routing Test")
        self.git("config", "user.email", "ci-routing@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.write("AGENTS.md", "instructions\n")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, stderr=subprocess.PIPE).decode().strip()

    def write(self, path, content="fixture\n"):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def run_detector(self, event_name, event, success=True):
        event_path = self.repo / "event.json"
        output = self.repo / "outputs"
        event_path.write_text(json.dumps(event))
        output.unlink(missing_ok=True)
        result = subprocess.run(
            ["python3", str(ROOT / "scripts/ci-component-paths.py"), "--event-name", event_name,
             "--event-path", str(event_path), "--output", str(output)],
            cwd=self.repo, text=True, capture_output=True, timeout=10)
        if not success:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(output.exists(), "Failed detection must not emit skip outputs")
            return {}
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split("=") for line in output.read_text().splitlines())
        self.assertEqual(set(values), set(routing.COMPONENTS))
        self.assertTrue(set(values.values()) <= {"true", "false"}, values)
        return {name: value == "true" for name, value in values.items()}

    def pr(self, base, head):
        return self.run_detector("pull_request", {"pull_request": {"base": {"sha": base}, "head": {"sha": head}}})

    def test_agents_only_pr_and_advanced_base_use_merge_base(self):
        self.git("checkout", "-b", "topic")
        self.write("AGENTS.md", "new policy\n")
        head = self.commit()
        self.git("checkout", "master")
        self.write("provider-swift/new.swift")
        advanced = self.commit()
        self.assertFalse(any(self.pr(advanced, head).values()))

    def test_multiple_commits_and_more_than_300_files_are_not_truncated(self):
        for index in range(350):
            self.write(f"docs/changed-{index}.md")
        self.commit()
        self.write("provider-swift/z-last.swift")
        head = self.commit()
        self.assertTrue(self.pr(self.base, head)["provider"])

    def test_added_deleted_renamed_paths_and_nul_delimited_names(self):
        self.write("provider-swift/original.swift", "same bytes\n")
        base = self.commit()
        (self.repo / "docs").mkdir()
        self.git("mv", "provider-swift/original.swift", "docs/moved.md")
        self.write("console-ui/file with\nnewline.ts")
        self.write("coordinator/new.go")
        head = self.commit()
        selected = self.pr(base, head)
        self.assertTrue(selected["provider"], "rename source must be considered")
        self.assertTrue(selected["console"])
        self.assertTrue(selected["coordinator"])
        base = head
        self.git("mv", "docs/moved.md", "provider-swift/new.swift")
        head = self.commit()
        self.assertTrue(self.pr(base, head)["provider"], "rename destination must be considered")
        self.git("rm", "provider-swift/new.swift")
        self.assertTrue(self.pr(head, self.commit())["provider"], "deletions must be considered")

    def test_submodule_pointer_change_selects_provider(self):
        self.git("update-index", "--add", "--cacheinfo", f"160000,{self.base},libs/mlx-swift-lm")
        self.git("commit", "-qm", "add gitlink")
        head = self.git("rev-parse", "HEAD")
        self.assertTrue(self.pr(self.base, head)["provider"])
        self.git("update-index", "--cacheinfo", f"160000,{head},libs/mlx-swift-lm")
        self.git("commit", "-qm", "bump gitlink")
        self.assertTrue(self.pr(head, self.git("rev-parse", "HEAD"))["provider"])

    def test_push_before_after_and_new_branch_and_manual(self):
        self.write("console-ui/new.ts")
        head = self.commit()
        event = {"before": self.base, "after": head, "ref": "refs/heads/topic"}
        selected = self.run_detector("push", event)
        self.assertTrue(selected["console"])
        self.assertFalse(selected["provider"])
        for ref in ("refs/heads/master", "refs/heads/main"):
            self.assertTrue(all(self.run_detector("push", {**event, "ref": ref}).values()))
        self.assertTrue(all(self.run_detector("push", {**event, "before": "0" * 40}).values()))
        self.assertTrue(all(self.run_detector("workflow_dispatch", {}).values()))

    def test_missing_invalid_revisions_and_unsupported_events_fail_closed(self):
        for before in ("f" * 40, "--help", "", None):
            self.run_detector("push", {"before": before, "after": self.base}, success=False)
        self.run_detector("pull_request", {}, success=False)
        self.run_detector("pull_request_target", {}, success=False)


class WorkflowRoutingTests(unittest.TestCase):
    def test_expensive_jobs_depend_on_successful_classifier(self):
        expected = {
            "ci.yml": {"test-coordinator": "coordinator", "lint-coordinator": "coordinator",
                       "test-prompt-sidecar": "sidecar", "test-provider": "provider",
                       "test-provider-sdk": "provider", "test-provider-parity": "provider",
                       "lint-console": "console"},
            "integration.yml": {"integration-tests": "integration"},
            "benchmarks.yml": {"benchmark": "benchmark"},
        }
        for name, lanes in expected.items():
            jobs = workflow.job_blocks((ROOT / ".github/workflows" / name).read_text())
            self.assertIn("uses: ./.github/workflows/component-changes.yml", jobs["changes"])
            self.assertIn("contents: read", jobs["changes"])
            for lane, component in lanes.items():
                self.assertIn("    needs: changes\n", jobs[lane])
                self.assertIn("    if: ${{ needs.changes.outputs." + component + " == 'true' }}\n", jobs[lane])
                self.assertNotIn("continue-on-error:", jobs[lane])
        ci = workflow.job_blocks((ROOT / ".github/workflows/ci.yml").read_text())
        for policy in ("release-integrity", "docs"):
            self.assertNotIn("    if:", ci[policy])
        self.assertIn("python3 scripts/test-ci-component-paths.py", ci["release-integrity"])
        self.assertIn("if: github.event_name == 'push'", ci["cache-swift"])

    def test_detector_has_full_history_no_credentials_or_api_truncation(self):
        text = (ROOT / ".github/workflows/component-changes.yml").read_text()
        self.assertIn("fetch-depth: 0", text)
        self.assertIn("persist-credentials: false", text)
        self.assertIn("contents: read", text)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("pull_request_target", text)
        self.assertNotIn("gh api", text)
        for name in routing.COMPONENTS:
            self.assertIn("value: ${{ jobs.changes.outputs." + name + " }}", text)
            self.assertIn(name + ": ${{ steps.paths.outputs." + name + " }}", text)

    def test_provider_aggregate_exhaustive_truth_table(self):
        jobs = workflow.job_blocks((ROOT / ".github/workflows/ci.yml").read_text())
        gate = jobs["provider-test-gate"]
        self.assertIn("needs: [changes, test-provider, test-provider-sdk, test-provider-parity]", gate)
        self.assertIn("if: ${{ always() }}", gate)
        self.assertNotIn("continue-on-error:", gate)
        step = workflow.step_blocks(gate)[0]
        for name, expression in {
            "CHANGES_RESULT": "needs.changes.result", "PROVIDER_CHANGED": "needs.changes.outputs.provider",
            "UNIT_RESULT": "needs.test-provider.result", "SDK_RESULT": "needs.test-provider-sdk.result",
            "PARITY_RESULT": "needs.test-provider-parity.result",
        }.items():
            self.assertIn(name + ": ${{ " + expression + " }}", step)
        command = workflow.run_command(step)
        results = ("success", "skipped", "failure", "cancelled")
        for detector, changed, unit, sdk, parity in itertools.product(results, ("true", "false", ""), results, results, results):
            result = subprocess.run(["bash", "-e", "-c", command], capture_output=True, timeout=5,
                                    env={**os.environ, "CHANGES_RESULT": detector, "PROVIDER_CHANGED": changed,
                                         "UNIT_RESULT": unit, "SDK_RESULT": sdk, "PARITY_RESULT": parity})
            expected = detector == "success" and ((changed == "true" and unit == sdk == parity == "success") or
                                                  (changed == "false" and unit == sdk == parity == "skipped"))
            self.assertEqual(result.returncode == 0, expected, (detector, changed, unit, sdk, parity))


if __name__ == "__main__":
    unittest.main()
