#!/usr/bin/env python3
"""Exercise the Darkbloom route step against a loopback HTTPS plane; pin callers.

The route step runs exactly as the workflow defines it, with throwaway TLS
credentials and the real curl/jq. It must choose only between each lane's
fallback label and the exact Darkbloom label array for its profile (qualified
by the lane's size when it sends one), and must never fail because of the
plane. Sizes are sent only while the job-size switch is exactly `on`; otherwise
the request is byte for byte the request without sizes. The workflow checks pin
every routed job, its fallback, size, timeout and read-only permissions, and
keep release paths on literal runners. Requires Bash, Python, jq, curl and
openssl.
"""

import http.server
import itertools
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import textwrap
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github/workflows"
ROUTER = WORKFLOWS / "darkbloom-route.yml"
LINUX = ["self-hosted", "linux", "ARM64", "darkbloom-linux-arm64"]
MACOS = ["self-hosted", "macOS", "ARM64", "darkbloom-macos-arm64"]
LINUX_FALLBACK = "blacksmith-4vcpu-ubuntu-2404"
MACOS_FALLBACK = "blacksmith-12vcpu-macos-27"
LANES = (f"release-integrity linux_arm64 {LINUX_FALLBACK}\n"
         f"test-provider macos_arm64 {MACOS_FALLBACK}\n"
         f"warm macos_arm64 {MACOS_FALLBACK} 2\n"
         f"docs linux_arm64 {LINUX_FALLBACK} 0\n")
FALLBACKS = {"release-integrity": LINUX_FALLBACK, "test-provider": MACOS_FALLBACK,
             "warm": MACOS_FALLBACK, "docs": LINUX_FALLBACK}
GRANTED = {"release-integrity": LINUX, "test-provider": MACOS,
           "warm": MACOS, "docs": LINUX_FALLBACK}
PULL_REQUEST_WARM = "${{ github.event_name == 'pull_request' && 2 || 0 }}"
# Every routed job: (profile, fallback label, count expression or None for 1)
# of each lane it reads.
ROUTED = {
    "docs-impact.yml": {
        "commit-signatures": ("linux_arm64", LINUX_FALLBACK, None),
        "docs-impact": ("linux_arm64", LINUX_FALLBACK, None),
    },
    "landing.yml": {"check": ("linux_arm64", LINUX_FALLBACK, None)},
    "desktop.yml": {"frontend": ("linux_arm64", LINUX_FALLBACK, None)},
    "nightly-linear-package.yml": {"test": ("linux_arm64", LINUX_FALLBACK, None)},
    "provider-release-cache.yml": {"warm": ("macos_arm64", MACOS_FALLBACK, PULL_REQUEST_WARM)},
}
# CI: the callers run provider-plan.yml, whose route job is the run's only
# route request (the plane routes a run attempt once), with the caller's own
# Linux lanes. Every macOS job (provider-tests.yml) reads `inputs.routes`; CI
# (master)'s Release Integrity and Docs Lint read the plan's output.
CALLERS = ("ci-dev.yml", "ci-master.yml")
PLAN = "provider-plan.yml"
COMPONENT = "${{{{ needs.components.outputs.{} == 'true' && {} || 0 }}}}"
BUILT = ("${{{{ (needs.components.outputs.{0} == 'true' || (github.event_name == 'push' && "
         "needs.tested.outputs.skip == 'true' && needs.components.outputs.changed_{0} == 'true')) && 1 || 0 }}}}")
# The sizes the sandbox plane signs (<vCPUs>x<GiB>).
VALID_SIZES = {"4x16", "4x24", "8x16", "12x32"}


def evaluate_counts(text, outcome):
    """Evaluate each `${{ condition && N || 0 }}` count as true (outcome "1") or false."""
    return re.sub(r"\$\{\{ .+? && (\d+) \|\| 0 \}\}",
                  lambda match: match.group(1) if outcome == "1" else "0", text)


def lane_jobs(count):
    """The jobs a `${{ condition && N || 0 }}` count asks for when its condition holds."""
    return int(evaluate_counts(count, "1"))


def requested(component, jobs=1):
    """A plan lane's count: its jobs when the component's tests run, else none."""
    return COMPONENT.format(component, jobs)


def built(component):
    """A build lane's count: 1 when its component's tests run or a push refreshes its caches."""
    return BUILT.format(component)


# Every routed macOS job of CI: lane -> (count, size, required), each size
# from the job's sampled memory (provider-plan.yml). The 9 blocking test jobs
# come first, critical path first. Two shards share each of the lanes
# test-cluster-2 (runtime shards 2 and 3), test-cluster-3 (runtime shards 4
# and 5) and test-cluster-focused, lanes the approval names. Then the build
# jobs and the release build checks, then the non-blocking GPU shards 1 and
# 3. No lane is `required`: while sizes are off every lane asks without one.
PLAN_LANES = {
    "test-cluster-2": (requested("cluster", 2), "12x32", False),
    "test-cluster-3": (requested("cluster", 2), "4x24", False),
    "test-cluster-focused": (requested("cluster", 2), "4x16", False),
    "test-provider-2": (requested("provider"), "4x24", False),
    "test-cluster-1": (requested("cluster"), "4x16", False),
    "test-provider-1": (requested("provider"), "4x16", False),
    "build-cluster": (built("cluster"), "8x16", False),
    "build-provider": (built("provider"), "12x32", False),
    "cluster-release-checks": (requested("cluster"), "8x16", False),
    "test-cluster-gpu-1": (requested("cluster"), "4x24", False),
    "test-cluster-gpu-3": (requested("cluster"), "4x24", False),
}
# The request CI sends while sizes are off, with every lane's jobs running: the
# lane table without its sizes, byte for byte.
UNSIZED_PLAN_REQUEST = [{"lane": "test-cluster-2", "profile": "macos_arm64", "count": 2},
                        {"lane": "test-cluster-3", "profile": "macos_arm64", "count": 2},
                        {"lane": "test-cluster-focused", "profile": "macos_arm64", "count": 2},
                        {"lane": "test-provider-2", "profile": "macos_arm64", "count": 1},
                        {"lane": "test-cluster-1", "profile": "macos_arm64", "count": 1},
                        {"lane": "test-provider-1", "profile": "macos_arm64", "count": 1},
                        {"lane": "build-cluster", "profile": "macos_arm64", "count": 1},
                        {"lane": "build-provider", "profile": "macos_arm64", "count": 1},
                        {"lane": "cluster-release-checks", "profile": "macos_arm64", "count": 1},
                        {"lane": "test-cluster-gpu-1", "profile": "macos_arm64", "count": 1},
                        {"lane": "test-cluster-gpu-3", "profile": "macos_arm64", "count": 1}]
# A shard that keeps a literal runner in a job whose other shards each read a
# lane of their own: Cluster GPU Tests shard 2 uses more memory than any
# signed size.
LITERAL_SHARD = {"test-cluster-gpu": "2"}
# A lane table with a `required` lane, which CI's own table no longer has: the
# router still holds such a lane while sizes are off.
HELD_LANES = (f"test macos_arm64 {MACOS_FALLBACK} 1 4x24\n"
              f"build macos_arm64 {MACOS_FALLBACK} 1 12x32 required\n")
MASTER_LINUX_LANES = (f"release-integrity linux_arm64 {LINUX_FALLBACK}", f"docs linux_arm64 {LINUX_FALLBACK}")
# (workflow, job): the expression its runs-on reads.
CI_ROUTED = {
    ("provider-tests.yml", "test-provider"): "inputs.routes", ("provider-tests.yml", "test-cluster"): "inputs.routes",
    ("provider-tests.yml", "test-cluster-focused"): "inputs.routes",
    ("provider-tests.yml", "build-cluster"): "inputs.routes", ("provider-tests.yml", "build-provider"): "inputs.routes",
    ("provider-tests.yml", "cluster-release-checks"): "inputs.routes",
    ("provider-tests.yml", "test-cluster-gpu"): "inputs.routes",
    ("ci-master.yml", "release-integrity"): "needs.plan.outputs.routes",
    ("ci-master.yml", "docs"): "needs.plan.outputs.routes",
}
# darkbloom-sandbox's GitHub-side watchdog (public/darkbloom-actions
# .github/workflows/watchdog.yml at d6d257c2), copied unchanged.
WATCHDOG = "darkbloom-watchdog.yml"
# The hourly full run of dev: a schedule on master that dispatches CI (dev) on
# dev. One GitHub-hosted job that routes nothing and tests nothing.
HOURLY = "ci-dev-hourly.yml"
# Credentialed, release, review or publication workflows keep literal runners.
UNROUTED = ("release-swift.yml", "release-desktop.yml", "provider-signing-validation.yml", "register-model.yml",
            "threat-model-review.yml", "bedrock-smoke.yml", "claude.yml", "codex.yml")
# The dev-branch release routes one job of the reusable release workflow: the
# SDK qualification shards, which read no secret and make no bytes that are
# signed. Staging and prod, and every other release job, keep Blacksmith.
RELEASE_CALLER, RELEASE, RELEASE_ROUTED = "release-dev-branch.yml", "release-provider.yml", "qualify-sdk-shard"
RELEASE_RUNS_ON = ("${{ inputs.environment == 'dev' && fromJSON(inputs.routes || '{}')"
                   "[format('qualify-sdk-{0}', matrix.shard)] || 'blacksmith-12vcpu-macos-27' }}")
# The plane grants a lane whole, so each shard of these jobs reads a lane of its
# own, `<job>-<shard>`, and gets a free sandbox even when the others fall back.
SHARDED = {"test-provider", "test-cluster-gpu"}
# These jobs' matrix names each shard's lane (`include: - {shard: N, lane: L}`);
# a lane that several shards read is requested for all of them.
LANE_MATRIX = {"test-cluster"}
# Master and dispatched warming feed release builds, so only PRs read the route.
RUNS_ON = {"warm": "${{ github.event_name == 'pull_request' && "
                   "fromJSON(needs.route.outputs.routes)['warm'] || 'blacksmith-12vcpu-macos-27' }}"}


def literal_block(text, key, indent):
    """Return the first `key: |` block at this indent, dedented as YAML reads it."""
    lines = text.split(f"{' ' * indent}{key}: |\n", 1)[1].splitlines()
    end = next((index for index, line in enumerate(lines)
                if line.strip() and not line.startswith(" " * (indent + 2))), len(lines))
    return textwrap.dedent("\n".join(lines[:end]))


def route_step():
    """Return the router's only run block, dedented exactly as the runner sees it."""
    return literal_block(ROUTER.read_text(), "run", 8)


def run_route_step(script, work, **variables):
    """Run the route step in `work` as the runner's `bash` shell does.

    The host's proxy, `CURL_*` and `SSL_CERT_*` settings are dropped, so only
    `variables` choose the plane and its CA. Returns the process, every `routes`
    output the step wrote and its step summary.
    """
    output, summary = work / "output", work / "summary"
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("CURL_", "SSL_CERT_"))
                   and key.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    environment.update(NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost",
                       GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
    environment.update(variables)
    result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                            cwd=work, env=environment, capture_output=True, text=True, timeout=60)
    written = output.read_text().splitlines() if output.exists() else []
    routes = [json.loads(line.split("=", 1)[1]) for line in written if line.startswith("routes=")]
    return result, routes, summary.read_text() if summary.exists() else ""


def jobs(workflow):
    body = workflow.split("\njobs:\n", 1)[1]
    headers = list(re.finditer(r"^  ([A-Za-z0-9_-]+):\n", body, re.MULTILINE))
    return {match.group(1): body[match.end():headers[index + 1].start()
                                 if index + 1 < len(headers) else len(body)]
            for index, match in enumerate(headers)}


def job_field(job, name):
    match = re.search(rf"^    {re.escape(name)}: (.+)$", job, re.MULTILINE)
    return match.group(1) if match else None


def needs(job):
    value = job_field(job, "needs") or ""
    return [name.strip() for name in value.strip("[]").split(",") if name.strip()]


def matrix_shards(job):
    """Return the job's `shard` matrix entries, or [] when it has none."""
    matrix = re.search(r"(?m)^        shard: \[([0-9, ]+)\]$", job)
    return [shard.strip() for shard in matrix.group(1).split(",")] if matrix else []


def matrix_lanes(job):
    """Return the `lane` of each `include` entry of the job's matrix, in order."""
    return re.findall(r"(?m)^          - \{shard: [0-9]+, lane: ([A-Za-z0-9_-]+)\}$", job)


def job_lanes(name, job):
    """Return the lanes a routed job reads: one per shard when SHARDED, each
    shard's matrix lane when LANE_MATRIX, else its own."""
    if name in LANE_MATRIX:
        return list(dict.fromkeys(matrix_lanes(job)))
    if name in SHARDED:
        return [f"{name}-{shard}" for shard in matrix_shards(job) if shard != LITERAL_SHARD.get(name)]
    return [name]


def requested_lanes(workflow, routed):
    """Return {lane: (profile, fallback, count, None, None)} that the caller's route job must request.

    These callers name no size.
    """
    return {lane: (*lane_spec, None, None) for name, lane_spec in routed.items()
            for lane in job_lanes(name, workflow[name])}


def lane_lines(route_job):
    """Return the caller's literal `lanes` block lines, before expression evaluation."""
    return literal_block(route_job, "lanes", 6).splitlines()


def route_lanes(route_job):
    """Parse the caller's `lanes` lines into {lane: (profile, fallback, count, size, required)}."""
    return route_lanes_text(lane_lines(route_job))


# `<lane> <profile> <fallback> [count [size [required]]]`; a count can be one
# `${{ ... }}` expression.
LANE_LINE = re.compile(r"(\S+) (\S+) (\S+)(?: (\$\{\{ .+? \}\}|\S+))?(?: (\S+))?(?: (\S+))?")


def route_lanes_text(lines):
    lanes = {}
    for line in lines:
        lane, profile, fallback, count, size, required = LANE_LINE.fullmatch(line).groups()
        lanes[lane] = (profile, fallback, count, size, required)
    return lanes


def plan_count(condition, jobs):
    """The plan's count for a job of provider-tests.yml: its jobs exactly when its `if` holds.

    The job's inputs are the plan's components, and its `skip` the tree lookup's.
    """
    inner = condition.removeprefix("${{ ").removesuffix(" }}")
    inner = inner.replace("inputs.skip", "needs.tested.outputs.skip").replace("inputs.", "needs.components.outputs.")
    # `a || b && N` would evaluate to `a`; group an alternative.
    if "||" in inner:
        inner = f"({inner})"
    return f"${{{{ {inner} && {jobs} || 0 }}}}"


def plan_lanes_text(outcome="1"):
    """CI's macOS lane lines from provider-plan.yml, every count evaluated one way."""
    route = jobs((WORKFLOWS / PLAN).read_text())["route"]
    return evaluate_counts("\n".join(lane_lines(route)[1:]) + "\n", outcome)


def sized(size):
    """The Darkbloom macOS labels of a lane sent with this size."""
    return [*MACOS[:-1], f"{MACOS[-1]}-{size}"]


def permissions(block, indent):
    """Return a declared permissions mapping (or inline value) at this indent."""
    match = re.search(rf"^{' ' * indent}permissions:(.*)$", block, re.MULTILINE)
    if match is None:
        return None
    if match.group(1).strip():
        return match.group(1).strip()
    entries = {}
    for line in block[match.end():].splitlines()[1:]:
        entry = re.match(rf"^{' ' * (indent + 2)}([a-z-]+): (\S+)$", line)
        if entry is None:
            break
        entries[entry.group(1)] = entry.group(2)
    return entries


def reply(**decisions):
    return {"route_id": "route-1", "expires_at": "2026-10-26T23:00:00Z", "lanes": decisions}


GRANT_ALL = reply(**{"release-integrity": {"target": "darkbloom", "runs_on": LINUX},
                     "test-provider": {"target": "darkbloom", "runs_on": MACOS},
                     "warm": {"target": "darkbloom", "runs_on": MACOS},
                     "docs": {"target": "darkbloom", "runs_on": LINUX}})


class Plane:
    """Loopback plane answering each POST with the next scripted (status, body, delay)."""

    def __init__(self, certificate, key, replies, tls=True):
        self.requests = []
        self.released = threading.Event()
        plane = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                plane.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                status, payload, delay = replies[min(len(plane.requests), len(replies)) - 1]
                if delay and plane.released.wait(delay):
                    return
                data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except OSError:
                    pass

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        if tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.url = f"{'https' if tls else 'http'}://127.0.0.1:{self.server.server_port}"
        self.worker = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05},
                                       daemon=True)

    def __enter__(self):
        self.worker.start()
        return self

    def __exit__(self, *_):
        self.released.set()
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()


class RouteStepTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="darkbloom-route-")
        root = Path(cls.scratch.name)
        cls.certificate, cls.key = root / "plane.pem", root / "plane-key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-keyout", str(cls.key), "-out", str(cls.certificate)],
                       check=True, capture_output=True, timeout=60)
        cls.script = route_step()

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def plane(self, *replies, tls=True):
        return Plane(self.certificate, self.key, replies or ((200, GRANT_ALL, 0),), tls=tls)

    def route(self, plane_url, routing="on", lanes=LANES, trust=True, **context):
        if routing == "on" and not plane_url:
            raise AssertionError("Tests must never fall through to the production plane")
        variables = dict(LANES=lanes, ROUTING=routing, PLANE_URL=plane_url, REPOSITORY="Layr-Labs/d-inference",
                         EVENT_NAME="push", HEAD_REPOSITORY="", RUN_ID="40408691758", RUN_ATTEMPT="2",
                         MACOS_LANES="", JOB_SHAPES="")
        variables.update(context)
        if trust:
            variables["CURL_CA_BUNDLE"] = str(self.certificate)
        work = Path(tempfile.mkdtemp(prefix="darkbloom-route-run-", dir=self.scratch.name))
        result, routes, summary = run_route_step(self.script, work, **variables)
        self.assertLessEqual(len(routes), 1, routes)
        return result, routes[0] if routes else None, summary

    def assertRoutes(self, result, routes, expected=FALLBACKS):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(routes, expected)

    def test_routing_is_off_unless_the_switch_is_exactly_on(self):
        with self.plane() as plane:
            for value in ("", "off", "ON", "On", "true", "1", " on"):
                with self.subTest(routing=value):
                    result, routes, summary = self.route(plane.url, routing=value)
                    self.assertRoutes(result, routes)
                    self.assertIn("Routing is off", summary)
        self.assertEqual(plane.requests, [])

    def test_request_contract_and_exact_label_grants(self):
        for suffix in ("", "/"):
            with self.subTest(url_suffix=suffix), self.plane() as plane:
                result, routes, summary = self.route(plane.url + suffix)
                self.assertRoutes(result, routes, GRANTED)
                request, = plane.requests
                self.assertEqual(request["path"], "/v1/ci/routes")
                self.assertEqual(request["headers"]["Content-Type"], "application/json")
                self.assertEqual(request["headers"]["User-Agent"], "darkbloom-route/1")
                # Lanes with no jobs are never requested, even if the plane offers them.
                self.assertEqual(json.loads(request["body"]), {
                    "repository": "Layr-Labs/d-inference", "run_id": 40408691758, "run_attempt": 2,
                    "lanes": [{"lane": "release-integrity", "profile": "linux_arm64", "count": 1},
                              {"lane": "test-provider", "profile": "macos_arm64", "count": 1},
                              {"lane": "warm", "profile": "macos_arm64", "count": 2}]})
                self.assertIn("route route-1, expires 2026-10-26T23:00:00Z", summary)
                self.assertIn("| `warm` | macos_arm64 | 2 | - | `self-hosted, macOS, ARM64, darkbloom-macos-arm64` "
                              "| darkbloom: granted |", summary)

    def test_only_an_exact_profile_label_array_is_used(self):
        decisions = {
            "plane fallback": {"target": "fallback", "reason": "no linux capacity"},
            "reordered": {"target": "darkbloom", "runs_on": LINUX[::-1]},
            "extra label": {"target": "darkbloom", "runs_on": LINUX + ["gpu"]},
            "missing label": {"target": "darkbloom", "runs_on": LINUX[:-1]},
            "other profile": {"target": "darkbloom", "runs_on": MACOS},
            "different case": {"target": "darkbloom", "runs_on": [label.lower() for label in LINUX]},
            "single label": {"target": "darkbloom", "runs_on": "darkbloom-linux-arm64"},
            "no labels": {"target": "darkbloom"},
            "unknown target": {"target": "Darkbloom", "runs_on": LINUX},
            "not an object": "darkbloom",
            "missing": None,
        }
        lanes = f"release-integrity linux_arm64 {LINUX_FALLBACK}\n"
        for name, decision in decisions.items():
            granted = {} if decision is None else {"release-integrity": decision}
            with self.subTest(decision=name), self.plane((200, reply(**granted), 0)) as plane:
                result, routes, summary = self.route(plane.url, lanes=lanes)
                self.assertRoutes(result, routes, {"release-integrity": LINUX_FALLBACK})
                self.assertEqual(len(plane.requests), 1)
                self.assertIn("plane: no linux capacity" if name == "plane fallback"
                              else "plane decision is missing or invalid", summary)

    def test_http_errors_fall_back_and_only_transient_errors_retry_once(self):
        for status, attempts in ((500, 2), (503, 2), (429, 2), (408, 2),
                                 (400, 1), (403, 1), (404, 1), (201, 1), (302, 1)):
            with self.subTest(status=status), self.plane((status, GRANT_ALL, 0)) as plane:
                result, routes, summary = self.route(plane.url)
                self.assertRoutes(result, routes)
                self.assertEqual(len(plane.requests), attempts)
                self.assertIn(f"plane request failed (HTTP {status})", summary)

    def test_one_retry_can_recover_a_transient_failure(self):
        with self.plane((503, {}, 0), (200, GRANT_ALL, 0)) as plane:
            result, routes, _ = self.route(plane.url)
        self.assertRoutes(result, routes, GRANTED)
        self.assertEqual(len(plane.requests), 2)

    def test_malformed_replies_fall_back_without_retry(self):
        decisions = GRANT_ALL["lanes"]
        bodies = {
            "not json": b"route granted",
            "empty": b"",
            "array": [GRANT_ALL],
            "two documents": json.dumps(GRANT_ALL).encode() * 2,
            "truncated": json.dumps(GRANT_ALL).encode()[:-1],
            "no route id": {"expires_at": "x", "lanes": decisions},
            "empty route id": {"route_id": "", "expires_at": "x", "lanes": decisions},
            "no expiry": {"route_id": "r", "lanes": decisions},
            "lanes list": {"route_id": "r", "expires_at": "x", "lanes": [decisions]},
        }
        for name, body in bodies.items():
            with self.subTest(body=name), self.plane((200, body, 0)) as plane:
                result, routes, summary = self.route(plane.url)
                self.assertRoutes(result, routes)
                self.assertEqual(len(plane.requests), 1)
                self.assertIn("plane reply is malformed", summary)

    def test_oversized_reply_is_abandoned(self):
        with self.plane((200, dict(GRANT_ALL, padding="x" * 70000), 0)) as plane:
            result, routes, summary = self.route(plane.url)
        self.assertRoutes(result, routes)
        self.assertEqual(len(plane.requests), 2)
        self.assertIn("HTTP 000", summary)

    def test_unresponsive_plane_times_out_into_fallbacks(self):
        with self.plane((200, GRANT_ALL, 30)) as plane:
            started = time.monotonic()
            result, routes, summary = self.route(plane.url)
            elapsed = time.monotonic() - started
        self.assertRoutes(result, routes)
        self.assertEqual(len(plane.requests), 2)
        # Two 5-second attempts and a 1-second pause, far below the 3-minute job limit.
        self.assertGreaterEqual(elapsed, 10)
        self.assertLess(elapsed, 20)
        self.assertIn("HTTP 000", summary)

    def test_unreachable_or_untrusted_plane_falls_back(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            closed = f"https://127.0.0.1:{probe.getsockname()[1]}"
        result, routes, _ = self.route(closed)
        self.assertRoutes(result, routes)
        # Certificate verification stays on: an untrusted plane is never asked.
        with self.plane() as plane:
            result, routes, _ = self.route(plane.url, trust=False)
        self.assertRoutes(result, routes)
        self.assertEqual(plane.requests, [])

    def test_plain_http_plane_is_never_contacted(self):
        with self.plane(tls=False) as plane:
            result, routes, summary = self.route(plane.url)
        self.assertRoutes(result, routes)
        self.assertEqual(plane.requests, [])
        self.assertIn("must start with https://", summary)

    def test_pull_requests_from_forks_never_contact_the_plane(self):
        with self.plane() as plane:
            for event, head in (("pull_request", "someone/d-inference"), ("pull_request", ""),
                                ("pull_request_target", "someone/d-inference")):
                with self.subTest(event=event, head=head):
                    result, routes, summary = self.route(plane.url, EVENT_NAME=event, HEAD_REPOSITORY=head)
                    self.assertRoutes(result, routes)
                    self.assertIn("forks keep their fallback runners", summary)
            self.assertEqual(plane.requests, [])
            result, routes, _ = self.route(plane.url, EVENT_NAME="pull_request",
                                           HEAD_REPOSITORY="Layr-Labs/d-inference")
        self.assertRoutes(result, routes, GRANTED)
        self.assertEqual(len(plane.requests), 1)

    def test_macos_lane_cap_keeps_lanes_in_order_and_asks_for_none_past_it(self):
        # LANES asks for test-provider (1 macOS job), then warm (2 macOS jobs).
        none = {**GRANTED, "test-provider": MACOS_FALLBACK, "warm": MACOS_FALLBACK}
        cases = {"": (["release-integrity", "test-provider", "warm"], GRANTED),
                 "3": (["release-integrity", "test-provider", "warm"], GRANTED),
                 "2": (["release-integrity", "test-provider"], {**GRANTED, "warm": MACOS_FALLBACK}),
                 "1": (["release-integrity", "test-provider"], {**GRANTED, "warm": MACOS_FALLBACK}),
                 "0": (["release-integrity"], none),
                 # A malformed cap is a repository setting: it asks for no
                 # macOS lane and never fails the route job.
                 "two": (["release-integrity"], none), "-1": (["release-integrity"], none),
                 "100": (["release-integrity"], none)}
        for value, (requested, expected) in cases.items():
            with self.subTest(cap=value), self.plane() as plane:
                result, routes, summary = self.route(plane.url, MACOS_LANES=value)
                self.assertRoutes(result, routes, expected)
                request, = plane.requests
                self.assertEqual([lane["lane"] for lane in json.loads(request["body"])["lanes"]], requested)
                if expected["warm"] == MACOS_FALLBACK:
                    self.assertIn("| `warm` | macos_arm64 | 2 | - | `blacksmith-12vcpu-macos-27` | fallback: over the "
                                  "macOS lane cap (DARKBLOOM_MACOS_LANES) |", summary)
                if value in ("two", "-1", "100"):
                    self.assertIn("DARKBLOOM_MACOS_LANES is not a number from 0 to 99", summary)
        # Routing off still names its own reason, and capped lanes never reach a plane.
        with self.plane() as plane:
            result, routes, summary = self.route(plane.url, routing="off", MACOS_LANES="0")
            self.assertRoutes(result, routes)
            self.assertIn("fallback: routing is off |", summary)
        self.assertEqual(plane.requests, [])

    def test_lanes_without_jobs_or_run_identity_send_nothing(self):
        with self.plane() as plane:
            result, routes, summary = self.route(plane.url, lanes=f"docs linux_arm64 {LINUX_FALLBACK} 0\n")
            self.assertRoutes(result, routes, {"docs": LINUX_FALLBACK})
            self.assertIn("No lane has jobs to run", summary)
            for name, value in (("RUN_ID", ""), ("RUN_ATTEMPT", "1x")):
                with self.subTest(missing=name):
                    result, routes, _ = self.route(plane.url, **{name: value})
                    self.assertRoutes(result, routes)
        self.assertEqual(plane.requests, [])

    def test_invalid_lane_configuration_fails_before_any_request(self):
        invalid = ("", "\n \n", f"docs linux_x64 {LINUX_FALLBACK}", "docs linux_arm64",
                   f"docs linux_arm64 {LINUX_FALLBACK} -1", f"docs linux_arm64 {LINUX_FALLBACK} 1.5",
                   f"docs linux_arm64 {LINUX_FALLBACK} 100", f"docs linux_arm64 {LINUX_FALLBACK} 01",
                   f"docs linux_arm64 {LINUX_FALLBACK} 1 extra", "docs linux_arm64 label;id",
                   f"docs.lint linux_arm64 {LINUX_FALLBACK}",
                   f"docs linux_arm64 {LINUX_FALLBACK}\ndocs macos_arm64 {MACOS_FALLBACK}",
                   # Sizes: the plane's grammar, macOS lanes only, and only `required` after them.
                   *(f"mac macos_arm64 {MACOS_FALLBACK} 1 {size}"
                     for size in ("4X24", "04x24", "4x024", "0x16", "4x0", "4x", "x24", "4x24x1", "4*24",
                                  "4x24-disk-50", "4 x24")),
                   f"docs linux_arm64 {LINUX_FALLBACK} 1 4x24",
                   f"mac macos_arm64 {MACOS_FALLBACK} 1 12x32 Required",
                   f"mac macos_arm64 {MACOS_FALLBACK} 1 12x32 required extra")
        for shapes in ("", "on"):
            with self.plane() as plane:
                for lanes in invalid:
                    with self.subTest(lanes=lanes, shapes=shapes):
                        result, routes, _ = self.route(plane.url, lanes=lanes, JOB_SHAPES=shapes)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("::error title=Darkbloom route configuration::", result.stdout)
                        self.assertIsNone(routes)
            self.assertEqual(plane.requests, [])

    def test_job_sizes_are_sent_only_when_the_switch_is_exactly_on(self):
        lanes = plan_lanes_text()
        # The lane table without its sizes.
        unsized = "".join(re.sub(r" [0-9]+x[0-9]+$", "", line) + "\n" for line in lanes.splitlines() if line)
        expected = (json.dumps({"repository": "Layr-Labs/d-inference", "run_id": 40408691758, "run_attempt": 2,
                                "lanes": UNSIZED_PLAN_REQUEST}, separators=(",", ":")) + "\n").encode()
        # The plane offers every lane its unsized labels; a lane takes only what it asked for.
        offer = reply(**{lane: {"target": "darkbloom", "runs_on": MACOS} for lane in PLAN_LANES})
        off = {lane: MACOS_FALLBACK if required else MACOS for lane, (_, _, required) in PLAN_LANES.items()}
        values = ("", "off", "ON", "On", "true", "1", " on", "on ")
        with self.plane((200, offer, 0)) as plane:
            result, routes, _ = self.route(plane.url, lanes=unsized)
            self.assertRoutes(result, routes, {lane: MACOS for lane in off if off[lane] == MACOS})
            for value in values:
                with self.subTest(shapes=value):
                    result, routes, summary = self.route(plane.url, lanes=lanes, JOB_SHAPES=value)
                    self.assertRoutes(result, routes, off)
                    # The log shows the exact request body.
                    self.assertIn("Request: " + expected.decode(), result.stdout)
                    self.assertIn("Job sizes are off: DARKBLOOM_JOB_SHAPES is not 'on'. No size was requested.",
                                  summary)
                    self.assertIn("| `test-cluster-2` | macos_arm64 | 2 | - | `self-hosted, macOS, ARM64, "
                                  "darkbloom-macos-arm64` | darkbloom: granted |", summary)
                    self.assertIn("| `cluster-release-checks` | macos_arm64 | 1 | - | `self-hosted, macOS, ARM64, "
                                  "darkbloom-macos-arm64` | darkbloom: granted |", summary)
        # Byte for byte the request of the table without sizes, for every value but `on`.
        self.assertEqual([request["body"] for request in plane.requests], [expected] * (1 + len(values)))

        # A `required` lane keeps its fallback without asking while sizes are off.
        offer = reply(**{lane: {"target": "darkbloom", "runs_on": MACOS} for lane in ("test", "build")})
        with self.plane((200, offer, 0)) as plane:
            result, routes, summary = self.route(plane.url, lanes=HELD_LANES)
        self.assertRoutes(result, routes, {"test": MACOS, "build": MACOS_FALLBACK})
        self.assertEqual(json.loads(plane.requests[0]["body"])["lanes"],
                         [{"lane": "test", "profile": "macos_arm64", "count": 1}])
        self.assertIn("| `build` | macos_arm64 | 1 | - | `blacksmith-12vcpu-macos-27` | "
                      "fallback: needs its size, and job sizes are off (DARKBLOOM_JOB_SHAPES) |", summary)

        # On: every lane asks for its size and takes only its sized labels. The
        # plane's fallback reasons reach the summary with the size asked.
        decisions = {lane: {"target": "darkbloom", "runs_on": sized(size)} for lane, (_, size, _) in PLAN_LANES.items()}
        reasons = {"test-cluster-1": "shape_not_signed", "build-provider": "unsupported_runner_class",
                   "cluster-release-checks": "image_not_available", "test-cluster-focused": "lane_not_enabled",
                   "test-provider-2": "profile_degraded", "test-provider-1": "unavailable"}
        decisions.update({lane: {"target": "fallback", "reason": reason} for lane, reason in reasons.items()})
        with self.plane((200, reply(**decisions), 0)) as plane:
            result, routes, summary = self.route(plane.url, lanes=lanes, JOB_SHAPES="on")
        self.assertRoutes(result, routes, {lane: MACOS_FALLBACK if lane in reasons else sized(size)
                                           for lane, (_, size, _) in PLAN_LANES.items()})
        request, = plane.requests
        self.assertEqual(json.loads(request["body"])["lanes"],
                         [{"lane": lane, "profile": "macos_arm64", "count": lane_jobs(count), "shape": size}
                          for lane, (count, size, _) in PLAN_LANES.items()])
        self.assertIn("Job sizes are on: DARKBLOOM_JOB_SHAPES is 'on'.", summary)
        for lane, reason in reasons.items():
            count, size, _ = PLAN_LANES[lane]
            self.assertIn(f"{lane}: {MACOS_FALLBACK} (plane: {reason}; size {size})\n", result.stdout)
            self.assertIn(f"| `{lane}` | macos_arm64 | {lane_jobs(count)} | {size} | `{MACOS_FALLBACK}` "
                          f"| fallback: plane: {reason} |", summary)
        self.assertIn("| `build-cluster` | macos_arm64 | 1 | 8x16 | `self-hosted, macOS, ARM64, "
                      "darkbloom-macos-arm64-8x16` | darkbloom: granted |", summary)

    def test_a_sized_lane_takes_only_the_labels_of_its_size(self):
        lanes = f"test-cluster-1 macos_arm64 {MACOS_FALLBACK} 1 4x24\n"

        def grant(labels):
            return reply(**{"test-cluster-1": {"target": "darkbloom", "runs_on": labels}})

        invalid = {"no size": MACOS, "other size": sized("12x32"), "upper case": sized("4X24"),
                   "with a disk": [*MACOS[:-1], f"{MACOS[-1]}-4x24-disk-50"],
                   "size label added": [*MACOS, f"{MACOS[-1]}-4x24"], "size label alone": [f"{MACOS[-1]}-4x24"],
                   "linux": LINUX}
        for name, labels in invalid.items():
            with self.subTest(decision=name), self.plane((200, grant(labels), 0)) as plane:
                result, routes, summary = self.route(plane.url, lanes=lanes, JOB_SHAPES="on")
                self.assertRoutes(result, routes, {"test-cluster-1": MACOS_FALLBACK})
                self.assertIn("plane decision is missing or invalid", summary)
        with self.plane((200, grant(sized("4x24")), 0)) as plane:
            result, routes, _ = self.route(plane.url, lanes=lanes, JOB_SHAPES="on")
        self.assertRoutes(result, routes, {"test-cluster-1": sized("4x24")})
        # Without sizes the lane asks without one, so a sized grant is not what it asked for.
        with self.plane((200, grant(sized("4x24")), 0)) as plane:
            result, routes, summary = self.route(plane.url, lanes=lanes)
        self.assertRoutes(result, routes, {"test-cluster-1": MACOS_FALLBACK})
        self.assertIn("plane decision is missing or invalid", summary)
        self.assertEqual(json.loads(plane.requests[0]["body"])["lanes"],
                         [{"lane": "test-cluster-1", "profile": "macos_arm64", "count": 1}])

    def test_macos_cap_keeps_the_test_lanes_first_with_sizes_on_or_off(self):
        lanes = plan_lanes_text()
        every = list(PLAN_LANES)
        tests = every[:6]
        caps = (("", every), ("14", every), ("13", every[:-1]), ("12", every[:-2]),
                ("11", [*tests, "build-cluster", "build-provider"]), ("10", [*tests, "build-cluster"]), ("9", tests),
                # A lane that does not fit is passed over; a later, smaller one can still fit.
                ("3", ["test-cluster-2", "test-provider-2"]))
        for shapes, (cap, asked) in itertools.product(("on", ""), caps):
            with self.subTest(shapes=shapes, cap=cap), self.plane() as plane:
                result, routes, summary = self.route(plane.url, lanes=lanes, JOB_SHAPES=shapes, MACOS_LANES=cap)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                request, = plane.requests
                self.assertEqual([lane["lane"] for lane in json.loads(request["body"])["lanes"]], asked)
                for lane in PLAN_LANES:
                    if lane in asked:
                        continue
                    self.assertEqual(routes[lane], MACOS_FALLBACK)
                    row = next(line for line in summary.splitlines() if line.startswith(f"| `{lane}` |"))
                    self.assertTrue(row.endswith("| fallback: over the macOS lane cap (DARKBLOOM_MACOS_LANES) |"), row)
        # A held lane takes no place under the cap: the lane after it still fits.
        held = "".join(reversed(HELD_LANES.splitlines(keepends=True)))
        with self.plane() as plane:
            result, routes, summary = self.route(plane.url, lanes=held, MACOS_LANES="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([lane["lane"] for lane in json.loads(plane.requests[0]["body"])["lanes"]], ["test"])
        self.assertIn("fallback: needs its size, and job sizes are off (DARKBLOOM_JOB_SHAPES) |", summary)

    def test_plane_text_cannot_inject_workflow_commands_or_markdown(self):
        hostile = "busy\n::error::forged | <img src=x> [link](https://example.invalid) `code`"
        payload = reply(**{"release-integrity": {"target": "fallback", "reason": hostile}})
        payload.update(route_id="r\n::warning::forged", expires_at="<b>soon</b>")
        with self.plane((200, payload, 0)) as plane:
            result, routes, summary = self.route(plane.url, lanes=f"release-integrity linux_arm64 {LINUX_FALLBACK}\n")
        self.assertRoutes(result, routes, {"release-integrity": LINUX_FALLBACK})
        for text in (result.stdout, summary):
            self.assertNotRegex(text, r"(?m)^::")
            for forbidden in ("<img", "<b>", "[link]", "`code`"):
                self.assertNotIn(forbidden, text)
        row = next(line for line in summary.splitlines() if line.startswith("| `release-integrity`"))
        self.assertEqual(row.count("|"), 7)


class RouteWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.texts = {path.name: path.read_text() for path in WORKFLOWS.glob("*.yml")}

    def test_every_workflow_is_classified(self):
        self.assertEqual(set(self.texts), set(ROUTED) | set(UNROUTED) | set(CALLERS) |
                         {"darkbloom-route.yml", "component-changes.yml", PLAN, "provider-tests.yml", WATCHDOG,
                          HOURLY, RELEASE_CALLER, RELEASE})

    def test_router_is_isolated_and_defaults_to_the_sandbox_plane(self):
        text = self.texts["darkbloom-route.yml"]
        header, body = text.split("\njobs:\n", 1)
        self.assertEqual(re.findall(r"(?m)^  ([a-z_]+):$", header.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]),
                         ["workflow_call"])
        self.assertIn("\npermissions: {}\n", header)
        select, = jobs(text).values()
        self.assertEqual(job_field(select, "runs-on"), "ubuntu-24.04")
        self.assertEqual(job_field(select, "permissions"), "{}")
        self.assertEqual(job_field(select, "timeout-minutes"), "3")
        self.assertEqual(len(re.findall(r"(?m)^      - ", select)), 1)
        for forbidden in ("uses:", "secrets", "checkout", "id-token", "${{ github.token"):
            self.assertNotIn(forbidden, body)
        self.assertIn("value: ${{ jobs.select.outputs.routes }}", header)
        self.assertIn("      routes: ${{ steps.route.outputs.routes }}\n", select)
        for name, expression in {"LANES": "inputs.lanes", "ROUTING": "vars.DARKBLOOM_ROUTING",
                                 "MACOS_LANES": "vars.DARKBLOOM_MACOS_LANES",
                                 "JOB_SHAPES": "vars.DARKBLOOM_JOB_SHAPES",
                                 "PLANE_URL": "vars.DARKBLOOM_SANDBOX_URL", "REPOSITORY": "github.repository",
                                 "EVENT_NAME": "github.event_name",
                                 "HEAD_REPOSITORY": "github.event.pull_request.head.repo.full_name",
                                 "RUN_ID": "github.run_id", "RUN_ATTEMPT": "github.run_attempt"}.items():
            self.assertIn(f"          {name}: ${{{{ {expression} }}}}\n", select)
        script = route_step()
        self.assertIn("plane_url=${PLANE_URL:-https://api-sandbox.darkbloom.dev}\n", script)
        self.assertIn('if [ "${ROUTING:-}" != on ]; then\n', script)
        self.assertIn('if [ "${JOB_SHAPES:-}" = on ]; then\n', script)
        profiles = json.loads(re.search(r"^profiles='(.+)'$", script, re.MULTILINE).group(1))
        self.assertEqual(profiles, {"linux_arm64": LINUX, "macos_arm64": MACOS})
        actionlint = (ROOT / ".github/actionlint.yaml").read_text()
        for label in ("darkbloom-linux-arm64", "darkbloom-macos-arm64"):
            self.assertIn(f"    - {label}\n", actionlint)

    def test_routed_jobs_read_their_lane_and_keep_their_fallback(self):
        for filename, expected in ROUTED.items():
            workflow = jobs(self.texts[filename])
            route = workflow["route"]
            with self.subTest(workflow=filename):
                self.assertIn("    uses: ./.github/workflows/darkbloom-route.yml\n", route)
                self.assertEqual(job_field(route, "permissions"), "{}")
                self.assertNotIn("secrets", route)
                self.assertEqual(route_lanes(route), requested_lanes(workflow, expected))
            for name, (_, _, count) in expected.items():
                job = workflow[name]
                with self.subTest(workflow=filename, job=name):
                    self.assertIn("route", needs(job))
                    if name in SHARDED:
                        self.assertTrue(matrix_shards(job))
                        lane = f"format('{name}-{{0}}', matrix.shard)"
                    else:
                        lane = f"'{name}'"
                    self.assertEqual(job_field(job, "runs-on"), RUNS_ON.get(
                        name, f"${{{{ fromJSON(needs.route.outputs.routes)[{lane}] }}}}"))
                    condition = job_field(job, "if")
                    if name != "warm":
                        # A lane is requested exactly when its job runs, once per
                        # matrix entry that reads it. `!cancelled()` cannot be
                        # evaluated in the route job and is true there.
                        jobs_requested = 1 if name in SHARDED else len(matrix_shards(job)) or 1
                        expected_count = None
                        if condition is not None:
                            inner = condition.removeprefix("${{ ").removesuffix(" }}")
                            inner = inner.replace("!cancelled() && ", "")
                            # `a || b && N` would evaluate to `a`; group an alternative.
                            if "||" in inner:
                                inner = f"({inner})"
                            expected_count = f"${{{{ {inner} && {jobs_requested} || 0 }}}}"
                        self.assertEqual(count, expected_count)
        warm = jobs(self.texts["provider-release-cache.yml"])["warm"]
        self.assertIn("lane: [release, qualification]", warm)
        self.assertEqual(job_field(warm, "if"),
                         "github.event_name == 'pull_request' || github.ref == 'refs/heads/master'")

    def test_routed_jobs_are_read_only_and_bounded(self):
        for filename, expected in ROUTED.items():
            text = self.texts[filename]
            workflow_permissions = permissions(text.split("\njobs:\n", 1)[0], 0)
            for name in expected:
                job = jobs(text)[name]
                with self.subTest(workflow=filename, job=name):
                    granted = permissions(job, 4) or workflow_permissions
                    self.assertIsInstance(granted, dict, "explicit read-only permissions required")
                    self.assertTrue(granted)
                    self.assertNotIn("id-token", granted)
                    self.assertTrue(set(granted.values()) <= {"read", "none"}, granted)
                    self.assertNotIn("secrets.", job)
                    self.assertNotRegex(job, r"(?m)^    (environment|services|container|secrets):")
                    timeout = job_field(job, "timeout-minutes")
                    self.assertIsNotNone(timeout)
                    self.assertLessEqual(int(timeout), 60)

    def test_router_accepts_every_caller_configuration(self):
        script = route_step()
        for filename in ROUTED:
            workflow = jobs(self.texts[filename])
            text = "\n".join(lane_lines(workflow["route"])) + "\n"
            for outcome in ("1", "0"):
                # Evaluate each `${{ condition && N || 0 }}` count both ways.
                lanes = evaluate_counts(text, outcome)
                with self.subTest(workflow=filename, requested=outcome), tempfile.TemporaryDirectory() as work:
                    result, routes, _ = run_route_step(
                        script, Path(work), LANES=lanes, ROUTING="", PLANE_URL="", EVENT_NAME="push",
                        HEAD_REPOSITORY="", REPOSITORY="Layr-Labs/d-inference", RUN_ID="1", RUN_ATTEMPT="1")
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(routes, [{lane: fallback for lane, (_, fallback, *_)
                                               in requested_lanes(workflow, ROUTED[filename]).items()}])

    def test_ci_routes_every_job_that_runs_code_through_one_plan(self):
        plan = jobs(self.texts[PLAN])
        route = plan["route"]
        self.assertIn("    uses: ./.github/workflows/darkbloom-route.yml\n", route)
        self.assertEqual(job_field(route, "permissions"), "{}")
        self.assertEqual(lane_lines(route)[0], "${{ inputs.linux_lanes }}")
        planned = route_lanes_text(lane_lines(route)[1:])
        self.assertEqual({lane: (count, size, required == "required")
                          for lane, (_, _, count, size, required) in planned.items()}, PLAN_LANES)
        self.assertEqual(list(planned), list(PLAN_LANES))
        self.assertTrue(all(profile == "macos_arm64" and fallback == MACOS_FALLBACK and required in (None, "required")
                            for profile, fallback, _, _, required in planned.values()))
        # The callers: CI (dev) adds no lane; CI (master) adds its Linux lanes.
        for filename in CALLERS:
            workflow = jobs(self.texts[filename])
            with self.subTest(workflow=filename):
                self.assertEqual(job_field(workflow["plan"], "uses"), f"./.github/workflows/{PLAN}")
                self.assertEqual(job_field(workflow["tests"], "uses"), "./.github/workflows/provider-tests.yml")
                self.assertEqual(needs(workflow["tests"]), ["plan"])
                self.assertNotIn("darkbloom-route.yml", self.texts[filename])
        self.assertEqual(set(jobs(self.texts["ci-dev.yml"])), {"plan", "tests", "hourly-failures"})
        self.assertNotIn("linux_lanes", self.texts["ci-dev.yml"])
        self.assertEqual(set(jobs(self.texts["ci-master.yml"])), {"plan", "tests", "release-integrity", "docs"})
        self.assertEqual(literal_block(jobs(self.texts["ci-master.yml"])["plan"], "linux_lanes", 6).splitlines(),
                         list(MASTER_LINUX_LANES))
        # Every routed job reads its own lane (each shard its own), and every
        # lane is read: no job hard-codes a Blacksmith label.
        read = set()
        for (filename, name), source in CI_ROUTED.items():
            job = jobs(self.texts[filename])[name]
            with self.subTest(workflow=filename, job=name):
                if name in LANE_MATRIX:
                    lane = "matrix.lane"
                    self.assertTrue(matrix_lanes(job))
                elif name in SHARDED:
                    lane = f"format('{name}-{{0}}', matrix.shard)"
                else:
                    lane = f"'{name}'"
                read |= set(job_lanes(name, job))
                routed = f"fromJSON({source})[{lane}]"
                if name in LITERAL_SHARD:
                    self.assertIn(LITERAL_SHARD[name], matrix_shards(job))
                    routed = f"matrix.shard == {LITERAL_SHARD[name]} && '{MACOS_FALLBACK}' || {routed}"
                self.assertEqual(job_field(job, "runs-on"), f"${{{{ {routed} }}}}")
                # A lane is requested exactly when its job runs; a shared lane
                # for every job of its matrix that reads it.
                if filename == "provider-tests.yml":
                    for each in job_lanes(name, job):
                        if name in LANE_MATRIX:
                            jobs_requested = matrix_lanes(job).count(each)
                        else:
                            jobs_requested = 1 if name in SHARDED else len(matrix_shards(job)) or 1
                        self.assertEqual(PLAN_LANES[each][0], plan_count(job_field(job, "if"), jobs_requested))
        self.assertEqual(read, set(PLAN_LANES) | {line.split()[0] for line in MASTER_LINUX_LANES})
        # The router accepts both callers' lane sets, with every count either
        # way and sizes on or off.
        script = route_step()
        for linux in ("", "\n".join(MASTER_LINUX_LANES)):
            text = "\n".join([linux, *lane_lines(route)[1:]]) + "\n"
            for outcome, shapes in itertools.product(("1", "0"), ("", "on")):
                with self.subTest(linux=bool(linux), requested=outcome, shapes=shapes), \
                        tempfile.TemporaryDirectory() as work:
                    result, routes, _ = run_route_step(
                        script, Path(work), LANES=evaluate_counts(text, outcome), ROUTING="", PLANE_URL="",
                        EVENT_NAME="push", HEAD_REPOSITORY="", REPOSITORY="Layr-Labs/d-inference", RUN_ID="1",
                        RUN_ATTEMPT="1", JOB_SHAPES=shapes)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    expected = {lane: MACOS_FALLBACK for lane in PLAN_LANES}
                    expected.update({line.split()[0]: LINUX_FALLBACK for line in linux.splitlines()})
                    self.assertEqual(routes, [expected])
        for filename in ("provider-tests.yml", "ci-dev.yml", "ci-master.yml", PLAN):
            for name, job in jobs(self.texts[filename]).items():
                runner = job_field(job, "runs-on")
                if runner and "fromJSON(" not in runner:
                    with self.subTest(workflow=filename, job=name):
                        # Only bookkeeping without tests stays GitHub-hosted;
                        # every macOS job reads its lane.
                        self.assertEqual(runner, "ubuntu-24.04")
                        self.assertIn(name, ("tested", "components", "ci-plan-checks", "provider-test-gate",
                                             "hourly-failures"))

    def test_ci_sizes_every_routed_macos_job_and_asks_for_the_test_lanes_first(self):
        sizes = {size for _, size, _ in PLAN_LANES.values()}
        self.assertLessEqual(sizes, VALID_SIZES)
        # 14 macOS jobs ask, with sizes on or off: the 9 blocking test jobs,
        # the 2 build jobs, the release build checks and GPU shards 1 and 3.
        self.assertEqual(sum(lane_jobs(count) for count, _, _ in PLAN_LANES.values()), 14)
        self.assertFalse(any(required for _, _, required in PLAN_LANES.values()))
        # The cap keeps lanes in table order: the blocking test lanes, then
        # the builds and the release build checks, then the non-blocking GPU shards.
        tests = list(PLAN_LANES)[:6]
        self.assertEqual(sum(lane_jobs(PLAN_LANES[lane][0]) for lane in tests), 9)
        self.assertTrue(all(lane.startswith("test-") and "-gpu-" not in lane for lane in tests))
        self.assertEqual(list(PLAN_LANES)[6:], ["build-cluster", "build-provider", "cluster-release-checks",
                                                "test-cluster-gpu-1", "test-cluster-gpu-3"])

    def test_dev_release_routes_only_its_qualification_shards(self):
        caller, release = jobs(self.texts[RELEASE_CALLER]), jobs(self.texts[RELEASE])
        self.assertEqual(set(caller), {"route", "dev"})
        route, dev = caller["route"], caller["dev"]
        self.assertIn("    uses: ./.github/workflows/darkbloom-route.yml\n", route)
        self.assertEqual(job_field(route, "permissions"), "{}")
        self.assertNotIn("secrets", route)
        # One lane per shard, so a shard falls back alone.
        shards = matrix_shards(release[RELEASE_ROUTED])
        self.assertTrue(shards)
        self.assertEqual(route_lanes(route), {f"qualify-sdk-{shard}": ("macos_arm64", MACOS_FALLBACK, None, None, None)
                                              for shard in shards})
        # A failed route job leaves the release on Blacksmith; it never stops it.
        self.assertEqual(needs(dev), ["route"])
        self.assertEqual(job_field(dev, "if"), "${{ !cancelled() && github.ref == 'refs/heads/dev' }}")
        self.assertIn("      routes: ${{ needs.route.outputs.routes }}\n", dev)
        # Only the dev environment reads the routes, and only for the shards:
        # they hold a read-only token and no secret. Every other release job,
        # and every job of staging and prod, keeps a literal Blacksmith runner.
        self.assertNotIn("uses: ./.github/workflows/darkbloom-route.yml", self.texts[RELEASE])
        self.assertNotIn("routes:", self.texts["release-swift.yml"])
        for name, job in release.items():
            with self.subTest(job=name):
                if name != RELEASE_ROUTED:
                    self.assertRegex(job_field(job, "runs-on"), r"^blacksmith-[a-z0-9-]+$")
                    self.assertNotIn("inputs.routes", job)
                    continue
                self.assertEqual(job_field(job, "runs-on"), RELEASE_RUNS_ON)
                self.assertEqual(permissions(job, 4), {"contents": "read"})
                self.assertNotIn("secrets.", job)
                self.assertNotRegex(job, r"(?m)^    (environment|services|container|secrets):")
                self.assertNotIn("upload-artifact", job)
                self.assertLessEqual(int(job_field(job, "timeout-minutes")), 60)
        # The router accepts the caller's lanes; with routing off every shard keeps Blacksmith.
        with tempfile.TemporaryDirectory() as work:
            result, routes, _ = run_route_step(
                route_step(), Path(work), LANES="\n".join(lane_lines(route)) + "\n", ROUTING="", PLANE_URL="",
                EVENT_NAME="push", HEAD_REPOSITORY="", REPOSITORY="Layr-Labs/d-inference", RUN_ID="1", RUN_ATTEMPT="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(routes, [{f"qualify-sdk-{shard}": MACOS_FALLBACK for shard in shards}])

    def test_release_and_credentialed_workflows_keep_literal_runners(self):
        for filename in UNROUTED:
            text = self.texts[filename]
            with self.subTest(workflow=filename):
                self.assertNotIn("darkbloom-route.yml", text)
                self.assertNotIn("needs.route", text)
                for runner in re.findall(r"(?m)^\s+runs-on: (.+)$", text):
                    self.assertRegex(runner, r"^blacksmith-[a-z0-9-]+$")
        for filename, text in self.texts.items():
            # The watchdog names the labels it looks for; it routes nothing.
            if filename not in ("darkbloom-route.yml", WATCHDOG):
                with self.subTest(workflow=filename):
                    for label in ("self-hosted", "darkbloom-linux-arm64", "darkbloom-macos-arm64"):
                        self.assertNotIn(label, text)
        # Unrouted jobs inside routed workflows keep literal runners as well.
        for filename, routed in ROUTED.items():
            for name, job in jobs(self.texts[filename]).items():
                if name not in routed and not job_field(job, "uses"):
                    with self.subTest(workflow=filename, job=name):
                        self.assertRegex(job_field(job, "runs-on"), r"^(blacksmith-[a-z0-9-]+|ubuntu-24\.04)$")

    def test_watchdog_rescues_only_this_repositorys_routed_runs(self):
        text = self.texts[WATCHDOG]
        header, body = text.split("\njobs:\n", 1)
        # Scheduled and on demand only; no token permission at the top.
        self.assertEqual(re.findall(r"(?m)^  ([a-z_]+):$", header.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]),
                         ["schedule", "workflow_dispatch"])
        self.assertIn("\npermissions: {}\n", header)
        watch, = jobs(text).values()
        self.assertEqual(job_field(watch, "runs-on"), "ubuntu-24.04")
        # Cancel and re-run, read and write its marker: on this repository only.
        self.assertEqual(permissions(watch, 4), {"actions": "write", "checks": "write"})
        self.assertIn('"${api%/}/repos/$REPOSITORY/$path"', body)
        self.assertIn("REPOSITORY: ${{ github.repository }}", body)
        for forbidden in ("uses:", "secrets.", "checkout", "id-token", "contents:"):
            self.assertNotIn(forbidden, body)
        # It acts only on runs with a queued Darkbloom-labelled job. The
        # signing and credentialed workflows never carry one; in a dev-branch
        # release only the qualification shards can, and signing waits for them.
        self.assertIn('index("self-hosted") != null and any(.[]; startswith("darkbloom-"))', body)
        for filename in UNROUTED:
            for runner in re.findall(r"(?m)^\s+runs-on: (.+)$", self.texts[filename]):
                self.assertNotIn("darkbloom", runner, filename)
            self.assertNotIn("self-hosted", self.texts[filename], filename)
        # The route job it re-runs is CI's: provider-plan.yml's, called as
        # `plan / route / Select Runners`, which it matches by suffix.
        self.assertIn('route_job=${ROUTE_JOB:-Select Runners}', body)
        self.assertIn('(.name | endswith(" / " + $name))', body)
        self.assertIn("    name: Select Runners\n", jobs(self.texts["darkbloom-route.yml"])["select"])
        # A listing reaches jq through a file or stdin, never as an argument:
        # one argument is at most 128 KiB on Linux, less than a busy day of
        # this repository's runs ("Argument list too long", exit 126).
        for listing in ("all", "more", "runs", "jobs", "cancelled"):
            self.assertNotRegex(body, rf'--arg(json)? [a-z_]+ "\${listing}"', listing)

    def test_hourly_full_run_only_dispatches_ci_dev_on_dev(self):
        text = self.texts[HOURLY]
        header, body = text.split("\njobs:\n", 1)
        # Hourly at minute 7 and on demand; no token permission at the top.
        self.assertEqual(re.findall(r"(?m)^  ([a-z_]+):$", header.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]),
                         ["schedule", "workflow_dispatch"])
        self.assertIn("    - cron: '7 * * * *'\n", header)
        self.assertIn("\npermissions: {}\n", header)
        dispatch, = jobs(text).values()
        self.assertEqual(job_field(dispatch, "runs-on"), "ubuntu-24.04")
        self.assertEqual(permissions(dispatch, 4), {"actions": "write", "contents": "read"})
        # It runs no action and no checkout, and dispatches only CI (dev) on
        # dev, unless a dispatched run of it is unfinished.
        for forbidden in ("uses:", "secrets.", "checkout", "id-token", "self-hosted", "darkbloom-"):
            self.assertNotIn(forbidden, body)
        self.assertEqual(re.findall(r"gh workflow run .+", body), ['gh workflow run ci-dev.yml --repo "$REPOSITORY" --ref dev'])
        self.assertIn("actions/workflows/ci-dev.yml/runs?event=workflow_dispatch&branch=dev", body)
        self.assertIn('select(.status != "completed")', body)

    def test_hourly_failures_report_only_dispatched_runs(self):
        # CI (dev)'s last job comments on the tracking issue when a job of a
        # dispatched run failed; it is the only job with issues: write.
        report = jobs(self.texts["ci-dev.yml"])["hourly-failures"]
        self.assertEqual(needs(report), ["plan", "tests"])
        self.assertEqual(job_field(report, "if"), "${{ always() && github.event_name == 'workflow_dispatch' && "
                                                  "contains(needs.*.result, 'failure') }}")
        self.assertEqual(permissions(report, 4), {"actions": "read", "issues": "write"})
        self.assertIn('select(.title == "Hourly full dev CI failures")', report)
        for forbidden in ("uses:", "secrets.", "checkout"):
            self.assertNotIn(forbidden, report)
        for filename in (*CALLERS, PLAN, "provider-tests.yml", "component-changes.yml", "darkbloom-route.yml", HOURLY):
            for name, job in jobs(self.texts[filename]).items():
                if (filename, name) != ("ci-dev.yml", "hourly-failures"):
                    self.assertNotIn("issues:", job, f"{filename} {name}")

    def test_classifier_gate_and_route_need_no_routed_runner(self):
        ci = jobs(self.texts["provider-tests.yml"])
        plan = jobs(self.texts[PLAN])
        # The build lanes read the tree lookup's skip, as their jobs do.
        self.assertEqual(needs(plan["route"]), ["tested", "components"])
        self.assertEqual(job_field(plan["route"], "if"), "${{ !cancelled() }}")
        self.assertEqual(job_field(ci["provider-test-gate"], "runs-on"), "ubuntu-24.04")
        self.assertNotIn("route", needs(ci["provider-test-gate"]))
        changes = jobs(self.texts["component-changes.yml"])["changes"]
        self.assertEqual(job_field(changes, "runs-on"), "ubuntu-24.04")
        self.assertIn("python3 scripts/test-darkbloom-route.py", jobs(self.texts["ci-master.yml"])["release-integrity"])
        self.assertEqual(permissions(self.texts["docs-impact.yml"].split("\njobs:\n", 1)[0], 0),
                         {"contents": "read"})


if __name__ == "__main__":
    unittest.main()
