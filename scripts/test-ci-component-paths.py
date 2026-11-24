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
        # Pull request `run-ci` runs cancel earlier runs of the same PR, while
        # unrelated label events get an isolated group so they never cancel an
        # active `run-ci` run. Rapid dev pushes coalesce; master pushes stay
        # independent.
        dev_concurrency = (ROOT / ".github/workflows/ci-dev.yml").read_text().split("\nconcurrency:\n", 1)[1].split("\njobs:\n", 1)[0]
        self.assertIn("(github.event_name == 'push' && 'ci-dev-push-dev')", dev_concurrency)
        self.assertIn("(github.event.label.name == 'run-ci' || github.event.label.name == 'run-gpu-ci') && format('{0}-pull_request-{1}', github.workflow, github.event.pull_request.number)",
                      dev_concurrency)
        self.assertIn("  cancel-in-progress: ${{ github.event_name == 'push' || "
                      "(github.event_name == 'pull_request' && (github.event.label.name == 'run-ci' || github.event.label.name == 'run-gpu-ci')) }}\n", dev_concurrency)
        master_concurrency = (ROOT / ".github/workflows/ci-master.yml").read_text().split("\nconcurrency:\n", 1)[1].split("\njobs:\n", 1)[0]
        self.assertIn("github.event.action == 'labeled' && github.event.label.name != 'run-ci' && github.event.label.name != 'run-gpu-ci'", master_concurrency)
        self.assertIn("  cancel-in-progress: ${{ github.event_name == 'pull_request' && "
                      "(github.event.action != 'labeled' || github.event.label.name == 'run-ci' || github.event.label.name == 'run-gpu-ci') }}\n", master_concurrency)
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
            "provider-swift/Tests/ClusterDiagnosticsChecks/run.sh": {"provider", "cluster"},
            "provider-swift/Tests/ClusterPlacementChecks/run-flow.sh": {"provider", "cluster"},
            # A provider file outside the cluster names that those runners compile.
            "provider-swift/Sources/ProviderCore/Diagnostics/GLM5NextGPULimitEligibility.swift": {"provider", "cluster"},
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
            "scripts/fixture_redirects.py": {"provider"},
            "scripts/provider-test-shards.py": {"provider"},
            "scripts/cluster-test-plan.py": {"provider", "cluster"},
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
            "scripts/test-provider-profiles-unprivileged.py", "scripts/test-qwen4-packaged-resources.py",
            "scripts/verify-prompt-parity.sh", "scripts/verify-nemotron-prompt-parity.sh",
            "scripts/install.sh", "scripts/test-install-atomic.sh", "scripts/test-desktop-api.py",
            "scripts/report-provider-coverage.sh",
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
        self.assertEqual(set(values), {*routing.COMPONENTS, "dependency_tier"})
        self.assertTrue(set(values.values()) <= {"true", "false"}, values)
        # Not a component: whether the change moves the build cache's dependency tier.
        self.dependency_tier = values.pop("dependency_tier") == "true"
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

    def test_master_pushes_select_every_component_while_pull_requests_use_diff(self):
        # Master pushes remain thorough (unless deduplicated via ci-tested-tree),
        # while pull requests into master, dev or stacked branches respect path
        # filtering so docs/landing/workflow PRs never force 14 macOS jobs.
        self.write("landing/new.ts")
        head = self.commit()
        everything = dict.fromkeys(routing.COMPONENTS, True)
        for ref in ("refs/heads/master", "refs/heads/main"):
            with self.subTest(ref=ref):
                self.assertEqual(self.run_detector("push", {"before": self.base, "after": head, "ref": ref}),
                                 everything)
        for branch in ("master", "main", "dev", "ci/stacked"):
            with self.subTest(base=branch):
                event = {"pull_request": {"base": {"sha": self.base, "ref": branch}, "head": {"sha": head}}}
                self.assertFalse(any(self.run_detector("pull_request", event).values()))
        # A provider-touching PR into master still selects provider.
        self.write("provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2.swift")
        provider_head = self.commit()
        event = {"pull_request": {"base": {"sha": head, "ref": "master"}, "head": {"sha": provider_head}}}
        self.assertEqual(self.run_detector("pull_request", event),
                         {"provider": True, "cluster": False, "mimo_audio": False})

    def test_dependency_tier_moves_with_a_gitlink_or_a_dependency_manifest(self):
        # The Swift build cache's dependency tier hashes every gitlink and every
        # Package.swift, Package.resolved and .gitmodules (scripts/provider-ci-cache.py);
        # a dev push that runs no provider test but moves it still builds the provider lane.
        def tier(base, head):
            self.pr(base, head)
            return self.dependency_tier

        self.write("provider-swift/Sources/ProviderCore/ProviderCore.swift")
        self.write("docs/guide.md")
        source = self.commit()
        self.assertFalse(tier(self.base, source), "sources and docs keep the tier")
        self.assertFalse(tier(source, source), "no change keeps the tier")
        # A push diffs as a pull request does; without a diff the tier may have moved.
        self.run_detector("push", {"before": self.base, "after": source, "ref": "refs/heads/dev"})
        self.assertFalse(self.dependency_tier)
        self.run_detector("push", {"before": "0" * 40, "after": source, "ref": "refs/heads/dev"})
        self.assertTrue(self.dependency_tier)
        self.run_detector("workflow_dispatch", {})
        self.assertTrue(self.dependency_tier)
        for path in ("provider-swift/Package.resolved", "provider-swift/Package.swift",
                     "libs/darkbloom-cluster/Package.swift", "desktop-app/Package.swift", ".gitmodules"):
            with self.subTest(path=path):
                before = self.git("rev-parse", "HEAD")
                content = ('[submodule "libs/fixture"]\n\tpath = libs/fixture\n\turl = https://example.invalid/fixture\n'
                           if path == ".gitmodules" else f"// pins of {path}\n")
                self.write(path, content)
                self.assertTrue(tier(before, self.commit()), path)
        # Names are read verbatim: only a last component equal to a manifest name counts.
        for path, moves in (("docs/x\nPackage.swift", False), ("odd\n/Package.swift", True)):
            with self.subTest(path=path):
                before = self.git("rev-parse", "HEAD")
                self.write(path)
                self.assertEqual(tier(before, self.commit()), moves, repr(path))
        self.write("libs/plain-file")
        plain = self.commit()
        # The gitlinks are index entries without a working tree, so the commits
        # below take the index alone (commit() would stage their removal).
        self.git("update-index", "--add", "--cacheinfo", f"160000,{self.base},libs/mlx-swift-lm")
        self.git("commit", "-qm", "add gitlink")
        added = self.git("rev-parse", "HEAD")
        self.assertTrue(tier(plain, added), "a new gitlink")
        self.git("update-index", "--cacheinfo", f"160000,{source},libs/mlx-swift-lm")
        self.git("commit", "-qm", "bump gitlink")
        bumped = self.git("rev-parse", "HEAD")
        self.assertTrue(tier(added, bumped), "a gitlink bump")
        self.git("update-index", "--cacheinfo", f"160000,{source},libs/plain-file")
        self.git("commit", "-qm", "file to gitlink")
        typed = self.git("rev-parse", "HEAD")
        self.assertTrue(tier(bumped, typed), "a file replaced by a gitlink")
        self.git("update-index", "--force-remove", "libs/mlx-swift-lm")
        self.git("commit", "-qm", "remove gitlink")
        self.assertTrue(tier(typed, self.git("rev-parse", "HEAD")), "a removed gitlink")

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
                               "pull_request": {"branches-ignore": "[master, main]", "types": "[labeled]"},
                               "workflow_dispatch": {}})
        # Pull requests run on request only: a label or ready for review,
        # never a push to the branch. A dispatch may name the commit to test.
        self.assertEqual(master, {"push": {"branches": "[master, main]"},
                                  "pull_request": {"branches": "[master, main]",
                                                   "types": "[labeled, ready_for_review]"},
                                  "workflow_dispatch": {}})
        # Both run the same plan and tests, whatever the base (Release
        # Integrity alone reads the base, for the branch's build default);
        # pull-request macOS tests run only when opted in via `run-ci` or
        # `run-gpu-ci`, which `unlabel` removes immediately on start.
        run_ci_guard = "github.event_name != 'pull_request' || github.event.label.name == 'run-ci' || github.event.label.name == 'run-gpu-ci'"
        for filename in ("ci-dev.yml", "ci-master.yml"):
            jobs = workflow.job_blocks((ROOT / ".github/workflows" / filename).read_text().split("\njobs:\n", 1)[1])
            with self.subTest(workflow=filename):
                self.assertNotIn("github.base_ref", jobs["plan"] + jobs["tests"])
                self.assertIn("    uses: ./.github/workflows/provider-plan.yml\n", jobs["plan"])
                self.assertIn("    uses: ./.github/workflows/provider-tests.yml\n", jobs["tests"])
                self.assertIn("      cluster_gpu: ${{ needs.plan.outputs.cluster_gpu }}\n", jobs["tests"])
                # The route asks for the provider build lane on the plan's output;
                # the job runs on the same value, passed through.
                self.assertIn("      warm_provider_cache: ${{ needs.plan.outputs.warm_provider_cache }}\n", jobs["tests"])
                self.assertIn(f"    needs: plan\n    if: ${{{{ !cancelled() && ({run_ci_guard}) }}}}\n", jobs["tests"])
                self.assertIn("    if: ${{ github.event_name == 'pull_request' && (github.event.label.name == 'run-ci' || github.event.label.name == 'run-gpu-ci') }}\n",
                              jobs["unlabel"])
                self.assertIn("    runs-on: ubuntu-24.04\n", jobs["unlabel"])
                self.assertIn('issues/$PR_NUMBER/labels/run-ci" >/dev/null 2>&1 || true', jobs["unlabel"])
                self.assertIn('issues/$PR_NUMBER/labels/run-gpu-ci" >/dev/null 2>&1 || true', jobs["unlabel"])
        self.assertFalse((ROOT / ".github/workflows/ci-dev-hourly.yml").exists())

    def test_nightly_dispatch_runs_ci_dev_with_the_gpu_shards_on_dev(self):
        # Pull requests run the Cluster GPU shards only with `run-gpu-ci`; a
        # daily dispatch of CI (dev) on dev runs them (a dispatch selects every
        # component, GPU included). GitHub runs the schedule from master only,
        # so the file dispatches dev's copy of ci-dev.yml and runs nothing else.
        text = (ROOT / ".github/workflows/ci-dev-nightly.yml").read_text()
        header, body = text.split("\njobs:\n", 1)
        self.assertEqual(header.split("\non:\n", 1)[1].split("\npermissions:", 1)[0],
                         "  schedule:\n    - cron: '31 7 * * *'\n")
        self.assertIn("\npermissions:\n  contents: read\n", header)
        self.assertEqual(re.findall(r"(?m)^  ([a-z_-]+):$", body), ["dispatch"])
        self.assertIn("    runs-on: ubuntu-24.04\n", body)
        self.assertIn("    permissions:\n      actions: write\n    steps:\n", body)
        self.assertIn('        run: gh workflow run ci-dev.yml --repo "$REPOSITORY" --ref dev\n', body)
        for forbidden in ("secrets.", "uses:", "checkout", "contents: write"):
            self.assertNotIn(forbidden, body)
        plan = (ROOT / ".github/workflows/provider-plan.yml").read_text()
        self.assertIn("[ \"$EVENT_NAME\" = workflow_dispatch ] ||", plan)

    def test_public_provider_workflows_have_no_backend_execution_or_private_access(self):
        for filename in ("ci-dev.yml", "ci-master.yml", "provider-tests.yml", "provider-plan.yml",
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
                         "provider-plan.yml"):
            text = (ROOT / ".github/workflows" / filename).read_text()
            self.assertNotIn("secrets.", text)
            self.assertNotRegex(text, r"(?m)^\s+(environment:|id-token:|repository:)")

    def test_expensive_jobs_depend_on_successful_classifier(self):
        # The plan (provider-plan.yml) runs the classifier and the tree lookup,
        # then routes only the lanes of the components it chose; the test jobs
        # read those components as inputs, on pull requests and pushes alike.
        # One job classifies, looks up and chooses; the route job follows it.
        plan = workflow.job_blocks((ROOT / ".github/workflows/provider-plan.yml").read_text().split("\njobs:\n", 1)[1])
        self.assertEqual(set(plan), {"commit", "components", "route"})
        steps = workflow.step_blocks(plan["components"])
        self.assertEqual([workflow.field(step, "name", indent=6) for step in steps],
                         [None, "Classify complete base-to-head Git diff", "Name the change this run tests",
                          "Look for a successful run that tested it", "Choose the components to test"])
        checkout, classify, tree, lookup, choose = steps
        self.assertEqual(workflow.uses(checkout), workflow.CHECKOUT)
        self.assertIn("    permissions:\n      contents: read\n      actions: read\n    outputs:\n", plan["components"])
        # Without run_tests, or when a dispatch's ref was refused, nothing is
        # classified: changes_result is the classifier step's outcome
        # (`skipped`) and every component is false or empty.
        for step in (checkout, classify):
            self.assertEqual(workflow.field(step, "if"), "${{ inputs.run_tests && needs.commit.result == 'success' }}")
        self.assertEqual(workflow.field(classify, "id"), "paths")
        self.assertEqual(workflow.continues_on_error(plan["components"]), ["Classify complete base-to-head Git diff"])
        self.assertEqual(workflow.run_command(classify), "python3 scripts/ci-component-paths.py")
        self.assertIn("      changes_result: ${{ steps.paths.outcome }}\n", plan["components"])
        # The lookup needs the classifier's components: a record must cover them.
        for step in (tree, lookup):
            self.assertEqual(workflow.field(step, "if"), "${{ steps.paths.outcome == 'success' }}")
        self.assertIn("          SELECTED: provider=${{ steps.paths.outputs.provider }},"
                      "cluster=${{ steps.paths.outputs.cluster }},"
                      "mimo_audio=${{ steps.paths.outputs.mimo_audio }}\n", lookup)
        # A dispatch's `ref` is resolved once (job `commit`); the classifier
        # waits for it, so a refused ref tests nothing.
        self.assertIn("    needs: commit\n    if: ${{ !cancelled() }}\n", plan["components"])
        # The choice runs after any failure but cancellation: a failed or
        # skipped lookup leaves skip empty, which tests.
        self.assertEqual(workflow.field(choose, "if"), "${{ !cancelled() }}")
        self.assertIn("          SKIP: ${{ steps.lookup.outputs.skip }}\n", choose)
        self.assertIn("    needs: components\n", plan["route"])
        for name in routing.COMPONENTS:
            self.assertIn(f"      {name}: ${{{{ steps.choose.outputs.{name} }}}}\n", plan["components"])
        ci = workflow.job_blocks((ROOT / ".github/workflows/provider-tests.yml").read_text().split("\njobs:\n", 1)[1])
        # No test job needs another job: each starts beside its lane's build
        # job, which runs when the component is selected, and waits for its
        # products (scripts/ci-test-products.py wait).
        lanes = {"test-provider": ("provider", "build-provider", "provider"),
                 "test-provider-gates": ("provider", "build-provider", "provider"),
                 "test-cluster": ("cluster", "build-cluster", "cluster"),
                 "test-cluster-focused": ("cluster", None, "cluster"),
                 "test-cluster-gpu": ("cluster_gpu", "build-cluster", "cluster"),
                 "cluster-release-checks": ("cluster", None, "cluster")}
        # The provider build also runs, without tests, on a dev push of a
        # tested tree that moves its cache's dependency tier (below).
        build_conditions = {
            "build-provider": "${{ inputs.provider == 'true' || inputs.warm_provider_cache == 'true' }}",
            "build-cluster": "${{ inputs.cluster == 'true' }}",
        }
        for lane, (condition_input, build, build_input) in lanes.items():
            with self.subTest(job=lane):
                self.assertNotRegex(ci[lane], r"(?m)^    needs:")
                if build:
                    self.assertIn(f"inputs.{build_input} == 'true'", build_conditions[build])
                    self.assertIn(f"    if: {build_conditions[build]}\n", ci[build])
                self.assertIn("    if: ${{ inputs." + condition_input + " == 'true' }}\n", ci[lane])
                if lane != "test-cluster-gpu":
                    self.assertEqual(workflow.continues_on_error(ci[lane]), [workflow.SAMPLER_STEPS[-1]])
        # Pull requests and pushes run the same blocking jobs; only cache saving
        # and the opt-in cluster_gpu gate in provider-plan.yml read the event.
        for name, job in ci.items():
            self.assertNotIn("github.event_name", job, name)
        self.assertNotIn("github.event_name", classify)
        # Verify the components step gates cluster_gpu on run-gpu-ci / master push / dispatch.
        choose_cmd = workflow.run_command(choose)
        gpu_cases = [
            # (event, ref, gpu_labeled, cluster, skip, expected_cluster_gpu)
            ("pull_request", "refs/pull/1/merge", "false", "true", "false", "false"),
            ("pull_request", "refs/pull/1/merge", "true", "true", "false", "true"),
            ("pull_request", "refs/pull/1/merge", "true", "false", "false", "false"),
            ("pull_request", "refs/pull/1/merge", "true", "true", "true", "false"),
            ("push", "refs/heads/dev", "false", "true", "false", "false"),
            ("push", "refs/heads/master", "false", "true", "false", "true"),
            ("push", "refs/heads/master", "false", "true", "true", "false"),
            ("workflow_dispatch", "refs/heads/dev", "false", "true", "false", "true"),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            for event_name, ref, gpu_labeled, cluster, skip, expected in gpu_cases:
                out_file = Path(tmpdir) / "out"
                out_file.write_text("")
                res = subprocess.run(
                    ["bash", "-e", "-c", choose_cmd], capture_output=True, text=True, timeout=5,
                    env={**os.environ, "GITHUB_OUTPUT": str(out_file), "RUN_TESTS": "true",
                         "SKIP": skip, "PROVIDER": cluster, "CLUSTER": cluster, "MIMO_AUDIO": "false",
                         "EVENT_NAME": event_name, "REF": ref, "GPU_LABELED": gpu_labeled},
                )
                self.assertEqual(res.returncode, 0, res.stderr)
                parsed = dict(line.split("=", 1) for line in out_file.read_text().splitlines())
                self.assertEqual(parsed["cluster_gpu"], expected, (event_name, ref, gpu_labeled, cluster, skip))
        # The provider build still runs, with no test job, only on a dev push
        # that runs no provider test (a tested tree, or no provider change)
        # and whose change moves the build cache's dependency tier.
        self.assertIn("          DEPENDENCY_TIER: ${{ steps.paths.outputs.dependency_tier }}\n", choose)
        self.assertIn("      warm_provider_cache: ${{ steps.choose.outputs.warm_provider_cache || 'false' }}\n",
                      plan["components"])
        warm_cases = [
            # (run_tests, event, ref, skip, provider, dependency_tier, expected warm_provider_cache)
            ("true", "push", "refs/heads/dev", "true", "true", "true", "true"),
            ("true", "push", "refs/heads/dev", "false", "false", "true", "true"),
            ("true", "push", "refs/heads/dev", "true", "true", "false", "false"),
            ("true", "push", "refs/heads/dev", "false", "true", "true", "false"),
            ("true", "push", "refs/heads/dev", "", "true", "true", "false"),
            ("true", "push", "refs/heads/dev", "true", "true", "", "false"),
            ("true", "push", "refs/heads/dev", "", "", "", "false"),
            ("true", "push", "refs/heads/master", "true", "true", "true", "false"),
            ("true", "push", "refs/heads/ci/topic", "true", "true", "true", "false"),
            ("true", "pull_request", "refs/pull/1/merge", "true", "true", "true", "false"),
            ("true", "pull_request", "refs/pull/1/merge", "false", "false", "true", "false"),
            ("true", "workflow_dispatch", "refs/heads/dev", "true", "true", "true", "false"),
            ("false", "push", "refs/heads/dev", "true", "true", "true", "false"),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            for run_tests, event_name, ref, skip, provider, tier, expected in warm_cases:
                out_file = Path(tmpdir) / "out"
                out_file.write_text("")
                res = subprocess.run(
                    ["bash", "-e", "-c", choose_cmd], capture_output=True, text=True, timeout=5,
                    env={**os.environ, "GITHUB_OUTPUT": str(out_file), "RUN_TESTS": run_tests,
                         "SKIP": skip, "PROVIDER": provider, "CLUSTER": "true", "MIMO_AUDIO": "true",
                         "DEPENDENCY_TIER": tier, "EVENT_NAME": event_name, "REF": ref, "GPU_LABELED": "false"},
                )
                self.assertEqual(res.returncode, 0, res.stderr)
                parsed = dict(line.split("=", 1) for line in out_file.read_text().splitlines())
                case = (run_tests, event_name, ref, skip, provider, tier)
                self.assertEqual(parsed["warm_provider_cache"], expected, case)
                # Warming never runs a test job: a tested tree's components stay false.
                if skip == "true" or run_tests != "true":
                    self.assertEqual((parsed["provider"], parsed["cluster"], parsed["mimo_audio"]),
                                     ("false", "false", "false"), case)
        # The lookup reads the event only to bind a record to its change.
        self.assertEqual(lookup.count("github.event_name"), 1)
        self.assertIn("          EVENT: ${{ github.event_name }}\n", lookup)
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
        self.assertEqual(set(workflow.job_blocks(dev.split("\njobs:\n", 1)[1])), {"unlabel", "plan", "tests"})
        self.assertIn("    uses: ./.github/workflows/provider-tests.yml\n", dev)

    def test_detector_has_full_history_no_credentials_or_api_truncation(self):
        text = (ROOT / ".github/workflows/provider-plan.yml").read_text()
        job = workflow.job_blocks(text.split("\njobs:\n", 1)[1])["components"]
        checkout = workflow.step_blocks(job)[0]
        self.assertEqual(job.count("actions/checkout@"), 1)
        self.assertIn("fetch-depth: 0", checkout)
        # Blobless: full commit and tree history, file contents on demand.
        self.assertIn("filter: blob:none", checkout)
        self.assertIn("persist-credentials: false", checkout)
        self.assertNotIn("sparse-checkout", checkout)
        self.assertIn("contents: read", job)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("pull_request_target", text)
        # The classifier reads the Git diff, never the API (no truncation).
        classify = workflow.step_blocks(job)[1]
        self.assertEqual(workflow.field(classify, "name", indent=6), "Classify complete base-to-head Git diff")
        self.assertNotIn("gh api", classify)
        self.assertNotIn("GITHUB_TOKEN", classify)
        for name in routing.COMPONENTS:
            self.assertIn("value: ${{ jobs.components.outputs." + name + " }}", text)
            self.assertIn(name.upper() + ": ${{ steps.paths.outputs." + name + " }}", job)
        self.assertFalse((ROOT / ".github/workflows/component-changes.yml").exists())

    def test_provider_aggregate_exhaustive_truth_table(self):
        jobs = workflow.job_blocks((ROOT / ".github/workflows/provider-tests.yml").read_text())
        gate = jobs["provider-test-gate"]
        self.assertIn("needs: [test-provider, test-provider-gates, test-cluster, test-cluster-focused, "
                      "cluster-release-checks, ci-plan-checks]", gate)
        self.assertNotIn("test-provider-sdk", gate)
        self.assertIn("if: ${{ always() }}", gate)
        self.assertNotIn("continue-on-error:", gate)
        step = workflow.step_blocks(gate)[0]
        for name, expression in {
            "CHANGES_RESULT": "inputs.changes_result", "PROVIDER_CHANGED": "inputs.provider",
            "CLUSTER_CHANGED": "inputs.cluster", "SKIP": "inputs.skip", "TESTED_RUN": "inputs.tested_run",
            "UNIT_RESULT": "needs.test-provider.result",
            "GATES_RESULT": "needs.test-provider-gates.result",
            "CLUSTER_RESULT": "needs.test-cluster.result",
            "CLUSTER_FOCUSED_RESULT": "needs.test-cluster-focused.result",
            "CLUSTER_RELEASE_RESULT": "needs.cluster-release-checks.result",
        }.items():
            self.assertIn(name + ": ${{ " + expression + " }}", step)
        command = workflow.run_command(step)
        results = ("success", "skipped", "failure", "cancelled")
        # Prompt Parity runs in a provider shard, so UNIT_RESULT carries it;
        # the gates that run once are Provider Gates', GATES_RESULT.
        self.assertNotIn("PARITY_RESULT", step)
        names = ("UNIT_RESULT", "GATES_RESULT", "CLUSTER_RESULT", "CLUSTER_FOCUSED_RESULT", "CLUSTER_RELEASE_RESULT")
        selections = ("true", "false", "")

        def passes(selected, lanes):
            return (selected == "true" and set(lanes) == {"success"}) or \
                   (selected == "false" and set(lanes) == {"skipped"})

        def passing(selected):
            return "skipped" if selected == "false" else "success"

        # Every result of each job, against every plan: the shards and the
        # cluster jobs in every combination, with Provider Gates at the result
        # its plan needs, then Provider Gates' every result with the other jobs
        # at theirs. The rule is a conjunction, so this is the full table
        # without its 4x longer product.
        cases = [(detector, changed, cluster, unit, passing(changed), *cluster_lanes)
                 for detector, changed, cluster, unit, *cluster_lanes in itertools.product(
                     results, selections, selections, *[results] * (len(names) - 1))]
        cases += [(detector, changed, cluster, passing(changed), gates, *[passing(cluster)] * 3)
                  for detector, changed, cluster, gates in itertools.product(
                      results, selections, selections, results)]
        for detector, changed, cluster, *lanes in cases:
            result = subprocess.run(["bash", "-e", "-c", command], capture_output=True, timeout=5,
                                    env={**os.environ, "CHANGES_RESULT": detector, "PROVIDER_CHANGED": changed,
                                         "CLUSTER_CHANGED": cluster, **dict(zip(names, lanes))})
            # A skipped cluster job passes only when the classifier did not
            # select the cluster jobs; a failed or cancelled one never passes.
            expected = detector == "success" and passes(changed, lanes[:2]) and passes(cluster, lanes[2:])
            self.assertEqual(result.returncode == 0, expected, (detector, changed, cluster, *lanes))


if __name__ == "__main__":
    unittest.main()
