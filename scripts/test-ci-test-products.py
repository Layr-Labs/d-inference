#!/usr/bin/env python3
"""Offline checks of the test products hand-off with the real git, tar and zstd.

The toolchain probe asks Xcode, which a Linux gate has not; the tests give it
fixed values. The fixed build path is a temporary directory here.
"""

import contextlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("ci_test_products", ROOT / "scripts/ci-test-products.py")
products = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(products)

TOOLCHAIN = {"versions": {"swift": "6.4.2", "xcode": "Xcode 27.2", "sdk": "27.2"},
             "builds": {"swift": "Apple Swift version 6.4.2 (swiftlang-6.4.2.1.4)", "xcode": "Build version 27B5038j",
                        "sdk": "26B5110a"}}
DEBUG = ".build/arm64-apple-macosx/debug"
BUNDLE = f"{DEBUG}/ProviderPackageTests.xctest/Contents"
KEPT = (f"{BUNDLE}/MacOS/ProviderPackageTests", f"{DEBUG}/darkbloom",
        f"{DEBUG}/Provider_Resources.bundle/model.json", f"{DEBUG}/mlx.metallib", f"{BUNDLE}/MacOS/mlx.metallib",
        f"{BUNDLE}/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
        ".build/checkouts/swift-nio/Sources/NIO.swift", ".build/checkouts/swift-nio/Tests.build/kept",
        ".build/checkouts/swift-nio/.git/objects/info/alternates", ".build/checkouts/swift-syntax/Macros-tool",
        ".build/build.db", f"{DEBUG}/description.json", ".build/workspace-state.json")
# The compile intermediates, the debug symbols (beside an executable and
# inside the test bundle), the host tools and SwiftPM's bare clones.
DROPPED = (f"{DEBUG}/ProviderCore.build/Engine.swift.o", f"{DEBUG}/ModuleCache/Foundation.pcm",
           f"{DEBUG}/index/store/v5/units", f"{DEBUG}/Modules/ProviderCore.swiftmodule",
           f"{DEBUG}/darkbloom.dSYM/Contents/Resources/DWARF/darkbloom",
           f"{BUNDLE}/MacOS/ProviderPackageTests.dSYM/Contents/Resources/DWARF/ProviderPackageTests",
           f"{DEBUG}/Macros-tool", f"{DEBUG}/Macros-tool.product/Objects.LinkFileList",
           f"{DEBUG}/Modules-tool/SwiftSyntax.swiftmodule", ".build/repositories/swift-nio-1234/HEAD")


def git(root, *args):
    subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)


class TestProductsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ci-test-products-")
        self.addCleanup(temporary.cleanup)
        self.fixed = Path(temporary.name).resolve() / "dinf"
        self.package = self.fixed / "provider-swift"
        self.package.mkdir(parents=True)
        (self.package / "Package.swift").write_text("// package\n")
        git(self.fixed, "init", "-q")
        git(self.fixed, "add", "-A")
        git(self.fixed, "commit", "-q", "-m", "tree")
        for relative in KEPT + DROPPED:
            path = self.package / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)
        for executable in KEPT[:2]:
            (self.package / executable).chmod(0o755)
        (self.package / ".build/debug").symlink_to("arm64-apple-macosx/debug")
        self.archive = Path(temporary.name) / "out" / "provider.tar.zst"
        self.environment = Path(temporary.name) / "github-env"
        for patch in (mock.patch.object(products, "FIXED_ROOT", self.fixed),
                      mock.patch.object(products, "toolchain", lambda: json.loads(json.dumps(TOOLCHAIN))),
                      mock.patch.dict(os.environ, {"GITHUB_ENV": str(self.environment)})):
            patch.start()
            self.addCleanup(patch.stop)

    def run_main(self, *argv, root=None):
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            status = products.main(["--root", str(root or self.fixed), *argv])
        return status, printed.getvalue()

    def pack_and_clear(self):
        self.assertEqual(self.run_main("pack", "provider", str(self.archive))[0], 0)
        shutil.rmtree(self.package / ".build")

    def test_round_trip_keeps_the_products_and_drops_what_no_test_step_reads(self):
        status, printed = self.run_main("pack", "provider", str(self.archive))
        self.assertEqual(status, 0, printed)
        self.assertIn("MiB of files", printed)
        self.assertIn("MiB compressed", printed)
        self.assertIn(f"{products.STAMP}=", self.environment.read_text())
        shutil.rmtree(self.package / ".build")
        # zstd packs from a pipe, so the frame declares the full 2 GiB window:
        # the unpack fails unless it passes LONG_WINDOW too.
        with mock.patch.dict(os.environ, {products.STAMP: "0"}):
            status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 0, printed)
        self.assertIn("downloaded in", printed)
        for relative in KEPT:
            self.assertEqual((self.package / relative).read_text(), relative)
        for relative in DROPPED:
            self.assertFalse((self.package / relative).exists(), relative)
        for executable in KEPT[:2]:
            self.assertTrue(os.access(self.package / executable, os.X_OK), executable)
        link = self.package / ".build/debug"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "arm64-apple-macosx/debug")
        status, printed = self.run_main("uploaded", str(self.archive))
        self.assertEqual(status, 0, printed)

    def test_products_of_another_toolchain_version_or_commit_are_refused(self):
        self.pack_and_clear()
        # Another build of the same versions (the release Xcode 27.2 against a
        # pre-release one, run 42037827790) warns and runs the products.
        other = {"versions": TOOLCHAIN["versions"], "builds": {**TOOLCHAIN["builds"], "xcode": "Build version 27B52"}}
        with mock.patch.object(products, "toolchain", lambda: other):
            status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 0, printed)
        self.assertIn("::warning title=Test products::", printed)
        self.assertIn("27B52", printed)
        shutil.rmtree(self.package / ".build")
        other = {"versions": {**TOOLCHAIN["versions"], "xcode": "Xcode 27.1"}, "builds": TOOLCHAIN["builds"]}
        with mock.patch.object(products, "toolchain", lambda: other):
            status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("::error title=Test products::", printed)
        self.assertIn("one toolchain", printed)
        shutil.rmtree(self.package / ".build")
        git(self.fixed, "commit", "-q", "--allow-empty", "-m", "later")
        status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("commit", printed)

    def test_a_test_job_never_unpacks_over_a_build_or_without_an_archive(self):
        self.assertEqual(self.run_main("pack", "provider", str(self.archive))[0], 0)
        status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("already exists", printed)
        status, printed = self.run_main("unpack", "provider", str(self.archive.with_name("missing.tar.zst")))
        self.assertEqual(status, 1)
        self.assertIn("download did not complete", printed)

    def test_products_outside_the_fixed_path_unknown_lanes_and_missing_builds_are_refused(self):
        elsewhere = self.fixed.parent / "elsewhere"
        (elsewhere / "provider-swift/.build").mkdir(parents=True)
        status, printed = self.run_main("pack", "provider", str(self.archive), root=elsewhere)
        self.assertEqual(status, 1)
        self.assertIn("fixed build path", printed)
        status, printed = self.run_main("pack", "sdk", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("Unknown lane", printed)
        status, printed = self.run_main("pack", "cluster", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("did not build", printed)
        self.assertFalse(self.archive.exists())

    def test_a_failed_archive_command_fails_the_step(self):
        # A corrupt archive: zstd fails, and so does the step.
        shutil.rmtree(self.package / ".build")
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b"not zstd")
        status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("failed (exit", printed)


class JobsAPI(http.server.BaseHTTPRequestHandler):
    """A loopback stand-in for GET /repos/{repository}/actions/runs/{run}/jobs.

    Each request takes the next answer: a list of jobs, an HTTP status, or
    (status, headers, body). The last answer repeats.
    """

    def do_GET(self):
        server = self.server
        server.requests.append((self.path, self.headers.get("Authorization")))
        answer = server.answers[min(len(server.requests), len(server.answers)) - 1]
        if isinstance(answer, int):
            answer = (answer, {}, b"")
        elif isinstance(answer, list):
            answer = (200, {"Content-Type": "application/json"},
                      json.dumps({"total_count": len(answer), "jobs": answer}).encode())
        status, headers, body = answer
        self.send_response(status)
        for name, value in {"Content-Length": str(len(body)), **headers}.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def job(name, status, conclusion=None):
    return {"name": name, "status": status, "conclusion": conclusion}


PLAN = job("plan / route / Select Runners", "completed", "success")
SHARD = job("Tests / Provider Unit Tests (shard 1)", "in_progress")
BUILD = "Tests / Build provider test products"


class WaitTests(unittest.TestCase):
    """`wait` against a real HTTP server on 127.0.0.1, with a fake clock."""

    def serve(self, *answers):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), JobsAPI)
        server.answers, server.requests = list(answers), []
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        patch = mock.patch.dict(os.environ, {
            "GITHUB_API_URL": f"http://127.0.0.1:{server.server_address[1]}", "GITHUB_REPOSITORY": "o/r",
            "GITHUB_RUN_ID": "42", "GITHUB_TOKEN": "token"})
        patch.start()
        self.addCleanup(patch.stop)
        return server

    def wait(self, lane="provider", **bounds):
        now = [0.0]

        def sleep(seconds):
            now[0] += seconds

        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            try:
                products.wait(lane, poll=15, clock=lambda: now[0], sleep=sleep, **bounds)
                failure = None
            except products.ProductsError as error:
                failure = str(error)
        return failure, printed.getvalue(), now[0]

    def test_waits_for_the_build_job_of_its_lane_to_succeed(self):
        server = self.serve([PLAN, SHARD, job(BUILD, "queued")], [PLAN, SHARD, job(BUILD, "in_progress")],
                            [PLAN, SHARD, job(BUILD, "in_progress")],
                            [PLAN, SHARD, job("Tests / Build cluster test products", "in_progress"),
                             job(BUILD, "completed", "success")])
        failure, printed, waited = self.wait()
        self.assertIsNone(failure, printed)
        self.assertEqual(waited, 45)
        self.assertEqual(len(server.requests), 4)
        path, authorization = server.requests[0]
        self.assertEqual(path, "/repos/o/r/actions/runs/42/jobs?filter=latest&per_page=100")
        self.assertEqual(authorization, "Bearer token")
        # One line per change of state, not one per poll.
        self.assertEqual(printed.count("in_progress"), 1)
        self.assertIn("waited 45 s for the provider products", printed)

    def test_a_build_that_did_not_succeed_fails_at_once(self):
        for conclusion in ("failure", "cancelled", "skipped", "timed_out"):
            with self.subTest(conclusion=conclusion):
                self.serve([job(BUILD, "in_progress")], [job(BUILD, "completed", conclusion)])
                failure, _, waited = self.wait()
                self.assertIn(f"ended {conclusion}", failure)
                self.assertIn("no provider products", failure)
                self.assertEqual(waited, 15)

    def test_failed_requests_are_retried_until_the_limit(self):
        # A server error, then a response cut short (http.client.IncompleteRead).
        cut_short = (200, {"Content-Length": "100"}, b'{"jobs": [')
        self.serve(502, cut_short, [job(BUILD, "completed", "success")])
        failure, printed, waited = self.wait()
        self.assertIsNone(failure, printed)
        self.assertEqual(waited, 30)
        self.assertIn("request failed", printed)
        self.assertIn("IncompleteRead", printed)
        self.serve(500)
        failure, _, waited = self.wait(limit=60)
        self.assertIn("had not ended after 60 s", failure)
        self.assertEqual(waited, 60)

    def test_a_rate_limited_request_waits_as_long_as_github_asks(self):
        success = [job(BUILD, "completed", "success")]
        # A secondary limit may name no wait (then a minute) or name it in Retry-After.
        secondary = (403, {}, b'{"message": "You have exceeded a secondary rate limit."}')
        self.serve(secondary, (429, {"Retry-After": "40"}, b""), 429, success)
        failure, printed, waited = self.wait()
        self.assertIsNone(failure, printed)
        self.assertEqual(waited, 60 + 40 + 60)
        # No request left: until the budget resets, and never past the limit.
        exhausted = {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(int(time.time()) + 120)}
        self.serve((403, exhausted, b""), success)
        failure, printed, waited = self.wait()
        self.assertIsNone(failure, printed)
        self.assertTrue(100 < waited <= 120, waited)
        self.serve((403, {**exhausted, "X-RateLimit-Reset": str(int(time.time()) + 3600)}, b""))
        failure, _, waited = self.wait(limit=300)
        self.assertIn("had not ended after 300 s", failure)
        self.assertEqual(waited, 300)

    def test_a_token_that_cannot_read_the_jobs_fails_at_once(self):
        denied = (403, {"X-RateLimit-Remaining": "998"}, b'{"message": "Resource not accessible by integration"}')
        for answer in (401, 403, 404, denied):
            with self.subTest(answer=answer):
                self.serve(answer)
                failure, _, waited = self.wait()
                self.assertIn("needs the token permission actions: read", failure)
                self.assertEqual(waited, 0)

    def test_a_build_still_running_at_the_limit_fails(self):
        self.serve([job(BUILD, "in_progress")])
        failure, _, waited = self.wait(limit=300)
        self.assertIn("had not ended after 300 s (in_progress)", failure)
        self.assertEqual(waited, 300)

    def test_a_missing_or_ambiguous_build_job_fails(self):
        self.serve([PLAN, SHARD])
        failure, _, waited = self.wait(missing=60)
        self.assertIn("lists no 'Build provider test products' job after 60 s", failure)
        self.assertEqual(waited, 60)
        self.serve([job(BUILD, "queued"), job("Other / Build provider test products", "queued")])
        failure, _, _ = self.wait()
        self.assertIn("2 jobs of this run", failure)

    def test_the_cluster_lane_waits_for_the_cluster_build_alone(self):
        self.serve([job(BUILD, "completed", "failure"), job("Build cluster test products", "completed", "success")])
        failure, printed, _ = self.wait("cluster")
        self.assertIsNone(failure, printed)

    def test_the_command_reports_a_failure_as_an_error_annotation(self):
        self.serve([job(BUILD, "completed", "failure")])
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            status = products.main(["wait", "provider"])
        self.assertEqual(status, 1)
        self.assertIn("::error title=Test products::", printed.getvalue())
        with mock.patch.dict(os.environ):
            del os.environ["GITHUB_TOKEN"]
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                self.assertEqual(products.main(["wait", "provider"]), 1)
            self.assertIn("GITHUB_TOKEN is not set", printed.getvalue())


if __name__ == "__main__":
    unittest.main()
