#!/usr/bin/env python3
"""Offline routing regressions: real Git histories and exact workflow wiring."""

import importlib.util
import itertools
import json
import os
import re
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
    def test_only_same_workflow_pr_revisions_share_cancellation_group(self):
        # Pull request revisions cancel each other; every push has a group of
        # its own (a push of a tested tree runs no test job, so none is skipped).
        for filename in ("ci-dev.yml", "ci-master.yml"):
            key = "github.event.pull_request.number || github.run_id"
            with self.subTest(workflow=filename):
                source = (ROOT / ".github/workflows" / filename).read_text()
                concurrency = source.split("\nconcurrency:\n", 1)[1].split("\njobs:\n", 1)[0]
                self.assertIn("  group: ${{ github.workflow }}-${{ github.event_name }}-${{ %s }}\n" % key,
                              concurrency)
                self.assertIn("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n", concurrency)
        # The shared test workflow takes its callers' concurrency.
        self.assertNotIn("\nconcurrency:", (ROOT / ".github/workflows/provider-tests.yml").read_text())

    def test_instructions_and_docs_never_select_expensive_lanes(self):
        paths = ["AGENTS.md", "docs/AGENTS.md", "docs/developer/test.md",
                 "provider-swift/AGENTS.md",
                 "scripts/docs-check.sh", "scripts/test-docs-impact-check.py",
                 "scripts/admin.sh", "landing/src/app/page.tsx"]
        self.assertFalse(any(routing.classify(paths).values()))

    def test_component_and_shared_dependency_matrix(self):
        cases = {
            "provider-swift/Sources/ProviderCore/ProviderCore.swift": {"provider"},
            "provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2.swift": {"provider"},
            "provider-swift/Tests/ProviderCoreTests/Inference/EngineV2Tests.swift": {"provider"},
            "provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedPipeExecutionOwner.swift":
                {"provider", "cluster"},
            "provider-swift/Sources/ProviderCore/Config/ClusterConfiguration.swift": {"provider", "cluster"},
            "provider-swift/Sources/darkbloom/ClusterCommand.swift": {"provider", "cluster"},
            "provider-swift/Sources/ProviderCore/Protocol/NativePairMessages.swift": {"provider", "cluster"},
            "provider-swift/Sources/ProviderCoreFoundation/Manifest.swift": {"provider", "cluster"},
            "provider-swift/Tests/ClusterOnboardingChecks/run.sh": {"provider", "cluster"},
            "provider-swift/Tests/ProviderCoreTests/Inference/DistributedServeLoopTests.swift": {"provider"},
            "provider-swift/Package.swift": {"provider", "cluster", "mimo_audio"},
            "provider-swift/Sources/ProviderCore/Inference/Engine/Factory/MiMo/MiMoV26ManagedMediaForwarding.swift":
                {"provider", "mimo_audio"},
            "provider-swift/Tests/ProviderCoreTests/MiMo/MiMoV26ManagedAudioProviderTests.swift": {"provider", "mimo_audio"},
            "scripts/prepare-mimo-audio-fixtures.py": {"provider", "mimo_audio"},
            # The audio fixture script runs this generator with --audio-source.
            "scripts/prepare-mimo-provider-fixtures.py": {"provider", "mimo_audio"},
            "libs/mlx-swift-lm": {"provider", "cluster", "mimo_audio"},
            "libs/mlx-swift-lm/Libraries/MLXLMCommon/Generate.swift": {"provider", "cluster", "mimo_audio"},
            "libs/mlx-swift": {"provider", "cluster", "mimo_audio"},
            "libs/mlx": {"provider", "cluster", "mimo_audio"},
            "libs/darkbloom-cluster/Package.swift": {"provider", "cluster"},
            "libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh": {"provider", "cluster"},
            "provider-swift/Tests/ClusterConsoleChecks/run.sh": {"provider", "cluster"},
            "provider-swift/Tests/ClusterPairingChecks/PairingTerminalChecks.swift": {"provider", "cluster"},
            "provider-swift/Sources/ProviderBuildEnvironment/BuildEnvironment.swift": {"provider", "cluster"},
            "handoff/TUI-wiring.md": {"provider", "cluster"},
            "fixtures/prompt-contract/v1/corpus.json": {"provider"},
            ".github/actions/provider-ci-build/action.yml": {"provider", "cluster"},
            ".github/actions/provider-ci-products/action.yml": {"provider", "cluster"},
            "scripts/ci-test-products.py": {"provider", "cluster"},
            "scripts/ci-resource-sampler.py": {"provider", "cluster"},
            ".github/workflows/provider-tests.yml": {"provider", "cluster", "mimo_audio"},
            ".github/workflows/ci-dev.yml": {"provider", "cluster", "mimo_audio"},
            ".github/workflows/provider-plan.yml": {"provider", "cluster", "mimo_audio"},
            "scripts/ci-tested-tree.py": {"provider", "cluster", "mimo_audio"},
            ".github/workflows/ci-master.yml": {"provider", "cluster", "mimo_audio"},
            "scripts/run-paged-kernel-tests.sh": {"provider"},
            "scripts/run-provider-tests.sh": {"provider"},
            "scripts/provider-ci-cold-retry.sh": {"provider", "cluster"},
            "scripts/verified_download_cache.py": {"provider"},
            "scripts/provider-test-shards.py": {"provider"},
            "scripts/cluster-test-plan.py": {"provider", "cluster"},
            "scripts/swift_test_lock_retry.py": {"provider", "cluster"},
            "coordinator/store/postgres/users.go": set(),
            "coordinator/protocol/messages.go": set(),
            "console-ui/package-lock.json": set(),
            "go.sum": set(),
            "scripts/run-coordinator-tests.py": set(),
            ".github/workflows/integration.yml": set(),
            ".github/workflows/benchmarks.yml": set(),
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual({name for name, value in routing.classify([path]).items() if value}, expected)
        for path in routing.COMMON:
            self.assertTrue(all(routing.classify([path]).values()), path)
        # Every cluster and MiMo audio input is also a provider input.
        for component, patterns in (("cluster", routing.CLUSTER), ("mimo_audio", routing.MIMO_AUDIO)):
            for pattern in patterns:
                path = pattern.replace("**", "x").replace("*", "Cluster" if component == "cluster" else "MiMo")
                self.assertTrue(routing.classify([path])[component], path)
                self.assertTrue(routing.classify([path])["provider"], path)

    def test_swift_prompt_corpora_select_provider(self):
        for filename in ("nemotron-prompt-edge-corpus.json", "nemotron-reference-corpus.json"):
            path = "provider-swift/Tests/ProviderCoreTests/Fixtures/" + filename
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file(), path)
                selected = routing.classify([path])
                self.assertEqual({name for name, value in selected.items() if value}, {"provider"})

    def test_selected_executable_dependencies_are_classified(self):
        # Explicitly pin the executable dependencies, not every scripts/** file.
        for path in (
            "scripts/prepare-provider-release-toolchain.sh", "scripts/install-release-cmake.sh",
            "scripts/prepare-metal-toolchain.py", "scripts/provider-ci-cache.py",
            "scripts/provider_release_cache/mtimes.py", "scripts/fetch-metallib.sh",
            "scripts/stage-test-metallib.sh", "scripts/run-provider-tests.sh",
            "scripts/run-nested-suite.sh", "scripts/run-paged-kernel-tests.sh",
            "scripts/run-exclusive-native-gpu-test.sh", "scripts/provider-test-shards.py",
            "scripts/provider-test-shard-weights.json",
            "scripts/cluster-test-plan.py",
            "scripts/run-provider-test-watchdog.py", "scripts/prepare-mimo-audio-fixtures.py",
            "scripts/prepare-mimo-provider-fixtures.py", "scripts/prepare-mimo-prompt-fixtures.py",
            "scripts/prepare-prompt-fixtures.py", "scripts/test-prepare-prompt-fixtures.py",
            "scripts/test-profile-inventory-auth.py", "scripts/test-qwen4-packaged-resources.py",
            "scripts/verify-prompt-parity.sh", "scripts/verify-nemotron-prompt-parity.sh",
            "scripts/install.sh", "scripts/test-install-atomic.sh", "scripts/test-desktop-api.py",
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
        self.write("coordinator/new.go")
        head = self.commit()
        selected = self.pr(base, head)
        self.assertTrue(selected["provider"], "rename source must be considered")
        self.assertEqual(set(selected), set(routing.COMPONENTS))
        base = head
        self.git("mv", "docs/moved.md", "provider-swift/new.swift")
        head = self.commit()
        self.assertTrue(self.pr(base, head)["provider"], "rename destination must be considered")
        self.git("rm", "provider-swift/new.swift")
        deleted = self.commit()
        self.assertTrue(self.pr(head, deleted)["provider"], "deletions must be considered")
        # Names are read verbatim: a newline must neither split a docs name into
        # a provider path nor hide a provider name behind Git's path quoting.
        self.write("docs/notes\nprovider-swift/new.swift")
        head = self.commit()
        self.assertFalse(self.pr(deleted, head)["provider"], "names must stay NUL-delimited")
        self.write("provider-swift/file with\nnewline.swift")
        self.assertTrue(self.pr(head, self.commit())["provider"], "names must stay unquoted")

    def test_submodule_pointer_change_selects_provider(self):
        self.git("update-index", "--add", "--cacheinfo", f"160000,{self.base},libs/mlx-swift-lm")
        self.git("commit", "-qm", "add gitlink")
        head = self.git("rev-parse", "HEAD")
        self.assertTrue(self.pr(self.base, head)["provider"])
        self.git("update-index", "--cacheinfo", f"160000,{head},libs/mlx-swift-lm")
        self.git("commit", "-qm", "bump gitlink")
        self.assertTrue(self.pr(head, self.git("rev-parse", "HEAD"))["provider"])

    def test_push_before_after_and_new_branch_and_manual(self):
        self.write("landing/new.ts")
        head = self.commit()
        event = {"before": self.base, "after": head, "ref": "refs/heads/topic"}
        self.assertFalse(any(self.run_detector("push", event).values()))
        # A provider-only change skips the cluster jobs, on a pull request and
        # on a push alike.
        self.write("provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2.swift")
        provider_only = self.commit()
        self.assertEqual(self.pr(head, provider_only),
                         {"provider": True, "cluster": False, "mimo_audio": False})
        for ref in ("refs/heads/topic", "refs/heads/dev"):
            self.assertEqual(self.run_detector("push", {"before": head, "after": provider_only, "ref": ref}),
                             {"provider": True, "cluster": False, "mimo_audio": False})
        self.write("libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/New.swift")
        cluster = self.commit()
        self.assertEqual(self.pr(provider_only, cluster),
                         {"provider": True, "cluster": True, "mimo_audio": False})
        # The MiMo audio gate and its 1.87 GB codec run only for their inputs.
        self.write("provider-swift/Tests/ProviderCoreTests/MiMo/MiMoV26ManagedAudioProviderTests.swift")
        audio = self.commit()
        self.assertEqual(self.pr(cluster, audio), {"provider": True, "cluster": False, "mimo_audio": True})
        # A push to dev selects by its diff, as a pull request into dev does.
        self.assertFalse(any(self.run_detector("push", {**event, "ref": "refs/heads/dev"}).values()))
        self.assertTrue(all(self.run_detector("push", {**event, "before": "0" * 40}).values()))
        self.assertTrue(all(self.run_detector("workflow_dispatch", {}).values()))

    def test_master_pushes_and_pull_requests_into_master_select_every_component(self):
        # Master is the release line: a docs-only change into master still
        # runs every component, so a master record always covers them all.
        self.write("landing/new.ts")
        head = self.commit()
        everything = dict.fromkeys(routing.COMPONENTS, True)
        for ref in ("refs/heads/master", "refs/heads/main"):
            with self.subTest(ref=ref):
                self.assertEqual(self.run_detector("push", {"before": self.base, "after": head, "ref": ref}),
                                 everything)
        for branch in ("master", "main"):
            with self.subTest(base=branch):
                event = {"pull_request": {"base": {"sha": self.base, "ref": branch}, "head": {"sha": head}}}
                self.assertEqual(self.run_detector("pull_request", event), everything)
        # Into dev or a stacked branch, the diff decides.
        for branch in ("dev", "ci/stacked"):
            with self.subTest(base=branch):
                event = {"pull_request": {"base": {"sha": self.base, "ref": branch}, "head": {"sha": head}}}
                self.assertFalse(any(self.run_detector("pull_request", event).values()))

    def test_missing_invalid_revisions_and_unsupported_events_fail_closed(self):
        for before in ("f" * 40, "--help", "", None):
            self.run_detector("push", {"before": before, "after": self.base}, success=False)
        self.run_detector("pull_request", {}, success=False)
        self.run_detector("pull_request_target", {}, success=False)


class WorkflowRoutingTests(unittest.TestCase):
    def test_every_pull_request_runs_exactly_one_ci_workflow(self):
        # CI (dev) runs for pull requests into any branch but master (dev and
        # stacked branches); CI (master) for pull requests into master. The
        # two filters are disjoint and cover every base.
        def triggers(filename):
            """The `on:` block as {event: {key: value}}, one level deep."""
            text = (ROOT / ".github/workflows" / filename).read_text()
            block = text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
            events = {}
            for line in block.splitlines():
                event = re.fullmatch(r"  ([a-z_]+):(?: (.*))?", line)
                option = re.fullmatch(r"    ([a-z-]+): (.*)", line)
                if event:
                    events[event.group(1)] = {}
                elif option:
                    events[list(events)[-1]][option.group(1)] = option.group(2)
            return events

        dev, master = triggers("ci-dev.yml"), triggers("ci-master.yml")
        self.assertEqual(dev, {"push": {"branches": "[dev]"},
                               "pull_request": {"branches-ignore": "[master, main]"}})
        self.assertEqual(master, {"push": {"branches": "[master, main]"},
                                  "pull_request": {"branches": "[master, main]"}})
        # Both run the same plan and tests, whatever the base (Release
        # Integrity alone reads the base, for the branch's build default).
        for filename in ("ci-dev.yml", "ci-master.yml"):
            jobs = workflow.job_blocks((ROOT / ".github/workflows" / filename).read_text().split("\njobs:\n", 1)[1])
            with self.subTest(workflow=filename):
                self.assertNotIn("github.base_ref", jobs["plan"] + jobs["tests"])
                self.assertIn("    uses: ./.github/workflows/provider-plan.yml\n", jobs["plan"])
                self.assertIn("    uses: ./.github/workflows/provider-tests.yml\n", jobs["tests"])
                self.assertIn("    needs: plan\n    if: ${{ !cancelled() }}\n", jobs["tests"])

    def test_public_provider_workflows_have_no_backend_execution_or_private_access(self):
        for filename in ("ci-dev.yml", "ci-master.yml", "provider-tests.yml", "component-changes.yml",
                         "provider-release-cache.yml",
                         "provider-signing-validation.yml", "release-swift.yml",
                         "release-provider.yml"):
            text = (ROOT / ".github/workflows" / filename).read_text()
            with self.subTest(filename=filename):
                for forbidden in ("actions/setup-go@", "go.mod", "coordinator/", "admin-ui/",
                                  "console-ui/", "e2e/", "install-release-rust.sh", "cargo "):
                    self.assertNotIn(forbidden, text)
                self.assertNotRegex(text, r"(?m)^\s+repository:")
        for filename in ("integration.yml", "benchmarks.yml", "telemetry-archive.yml", "ci.yml"):
            self.assertFalse((ROOT / ".github/workflows" / filename).exists())
        for filename in ("ci-dev.yml", "ci-master.yml", "provider-tests.yml", "provider-release-cache.yml",
                         "component-changes.yml"):
            text = (ROOT / ".github/workflows" / filename).read_text()
            self.assertNotIn("secrets.", text)
            self.assertNotRegex(text, r"(?m)^\s+(environment:|id-token:|repository:)")

    def test_expensive_jobs_depend_on_successful_classifier(self):
        # The plan (provider-plan.yml) runs the classifier and the tree lookup,
        # then routes only the lanes of the components it chose; the test jobs
        # read those components as inputs, on pull requests and pushes alike.
        plan = workflow.job_blocks((ROOT / ".github/workflows/provider-plan.yml").read_text().split("\njobs:\n", 1)[1])
        self.assertIn("uses: ./.github/workflows/component-changes.yml", plan["changes"])
        self.assertIn("contents: read", plan["changes"])
        self.assertIn("    needs: [changes, tested]\n", plan["components"])
        # The lookup needs the classifier's components: a record must cover them.
        self.assertIn("    needs: changes\n    if: ${{ !cancelled() && needs.changes.result == 'success' }}\n",
                      plan["tested"])
        self.assertIn("          SELECTED: provider=${{ needs.changes.outputs.provider }},"
                      "cluster=${{ needs.changes.outputs.cluster }},"
                      "mimo_audio=${{ needs.changes.outputs.mimo_audio }}\n", plan["tested"])
        self.assertIn("    needs: [tested, components]\n", plan["route"])
        for name in routing.COMPONENTS:
            self.assertIn(f"      {name}: ${{{{ steps.choose.outputs.{name} }}}}\n", plan["components"])
        ci = workflow.job_blocks((ROOT / ".github/workflows/provider-tests.yml").read_text().split("\njobs:\n", 1)[1])
        # Each test job needs only its lane's build job, which runs when the
        # component is selected.
        lanes = {"test-provider": ("provider", "build-provider"), "test-cluster": ("cluster", "build-cluster"),
                 "test-cluster-focused": ("cluster", None), "test-cluster-gpu": ("cluster", "build-cluster"),
                 "cluster-release-checks": ("cluster", None)}
        for lane, (component, build) in lanes.items():
            with self.subTest(job=lane):
                if build:
                    self.assertIn(f"    needs: {build}\n", ci[lane])
                    self.assertIn(f"    if: ${{{{ inputs.{component} == 'true' ||", ci[build])
                else:
                    self.assertNotRegex(ci[lane], r"(?m)^    needs:")
                self.assertIn("    if: ${{ inputs." + component + " == 'true' }}\n", ci[lane])
                if lane != "test-cluster-gpu":
                    self.assertEqual(workflow.continues_on_error(ci[lane]), [workflow.SAMPLER_STEPS[-1]])
        # Pull requests and pushes run the same jobs: only cache saving and the
        # build jobs' refresh of a tested tree on a push read the event.
        for name, job in ci.items():
            if name not in workflow.BUILD_JOBS:
                self.assertNotIn("github.event_name", job, name)
        self.assertNotIn("github.event_name", "".join(plan[name] for name in ("changes", "components")))
        # The lookup reads the event only to bind a record to its change.
        self.assertEqual(plan["tested"].count("github.event_name"), 1)
        self.assertIn("          EVENT: ${{ github.event_name }}\n", plan["tested"])
        # The Provider SDK Tests lane is gone (David, 2026-11-04): its suites run
        # in the SDK's own Fork Tests.
        self.assertNotIn("test-provider-sdk", ci)
        self.assertNotIn("sdk", routing.COMPONENTS)
        # No Mac job exists only to audit or to run the metadata runners.
        self.assertNotIn("test-provider-summary", ci)
        self.assertNotIn("test-cluster-checks", ci)
        self.assertNotIn("cache-swift", ci)
        # Release Integrity and Docs Lint run for master only, after the plan
        # whose route they read; nothing but cancellation skips them.
        master = workflow.job_blocks((ROOT / ".github/workflows/ci-master.yml").read_text())
        for policy in ("release-integrity", "docs"):
            self.assertIn("    needs: plan\n    if: ${{ !cancelled() }}\n", master[policy])
        self.assertIn("python3 scripts/test-ci-component-paths.py", master["release-integrity"])
        dev = (ROOT / ".github/workflows/ci-dev.yml").read_text()
        self.assertEqual(set(workflow.job_blocks(dev.split("\njobs:\n", 1)[1])), {"plan", "tests"})
        self.assertIn("    uses: ./.github/workflows/provider-tests.yml\n", dev)

    def test_detector_has_full_history_no_credentials_or_api_truncation(self):
        text = (ROOT / ".github/workflows/component-changes.yml").read_text()
        self.assertIn("fetch-depth: 0", text)
        # Blobless: full commit and tree history, file contents on demand.
        self.assertIn("filter: blob:none", text)
        self.assertIn("persist-credentials: false", text)
        self.assertIn("contents: read", text)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("pull_request_target", text)
        self.assertNotIn("gh api", text)
        for name in routing.COMPONENTS:
            self.assertIn("value: ${{ jobs.changes.outputs." + name + " }}", text)
            self.assertIn(name + ": ${{ steps.paths.outputs." + name + " }}", text)

    def test_provider_aggregate_exhaustive_truth_table(self):
        jobs = workflow.job_blocks((ROOT / ".github/workflows/provider-tests.yml").read_text())
        gate = jobs["provider-test-gate"]
        self.assertIn("needs: [test-provider, test-cluster, test-cluster-focused, cluster-release-checks]", gate)
        self.assertNotIn("test-provider-sdk", gate)
        self.assertIn("if: ${{ always() }}", gate)
        self.assertNotIn("continue-on-error:", gate)
        step = workflow.step_blocks(gate)[0]
        for name, expression in {
            "CHANGES_RESULT": "inputs.changes_result", "PROVIDER_CHANGED": "inputs.provider",
            "CLUSTER_CHANGED": "inputs.cluster", "SKIP": "inputs.skip", "TESTED_RUN": "inputs.tested_run",
            "UNIT_RESULT": "needs.test-provider.result",
            "CLUSTER_RESULT": "needs.test-cluster.result",
            "CLUSTER_FOCUSED_RESULT": "needs.test-cluster-focused.result",
            "CLUSTER_RELEASE_RESULT": "needs.cluster-release-checks.result",
        }.items():
            self.assertIn(name + ": ${{ " + expression + " }}", step)
        command = workflow.run_command(step)
        results = ("success", "skipped", "failure", "cancelled")
        # Prompt Parity runs in a provider shard, so UNIT_RESULT carries it.
        self.assertNotIn("PARITY_RESULT", step)
        names = ("UNIT_RESULT", "CLUSTER_RESULT", "CLUSTER_FOCUSED_RESULT", "CLUSTER_RELEASE_RESULT")
        selections = ("true", "false", "")

        def passes(selected, lanes):
            return (selected == "true" and set(lanes) == {"success"}) or \
                   (selected == "false" and set(lanes) == {"skipped"})

        for detector, changed, cluster, *lanes in itertools.product(
                results, selections, selections, *[results] * len(names)):
            result = subprocess.run(["bash", "-e", "-c", command], capture_output=True, timeout=5,
                                    env={**os.environ, "CHANGES_RESULT": detector, "PROVIDER_CHANGED": changed,
                                         "CLUSTER_CHANGED": cluster, **dict(zip(names, lanes))})
            # A skipped cluster job passes only when the classifier did not
            # select the cluster jobs; a failed or cancelled one never passes.
            expected = detector == "success" and passes(changed, lanes[:1]) and passes(cluster, lanes[1:])
            self.assertEqual(result.returncode == 0, expected, (detector, changed, cluster, *lanes))


if __name__ == "__main__":
    unittest.main()
