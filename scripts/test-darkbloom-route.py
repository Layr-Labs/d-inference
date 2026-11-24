#!/usr/bin/env python3
"""Exercise the Darkbloom route step against a loopback HTTPS plane; pin callers.

The route step runs exactly as the workflow defines it, with throwaway TLS
credentials and the real curl/jq. It must choose only between each lane's
fallback label and the exact Darkbloom label array for its profile (qualified
by the lane's size and placement when it sends them), and must never fail
because of the plane unless `require-darkbloom` is true. The workflow is
darkbloom-sandbox's route.yml, byte for byte. The workflow checks pin every
routed job, its fallback, size, timeout and read-only permissions, and keep
release paths on literal runners: only the release's SDK qualification shards
are routed, in a call that passes no secrets. Requires Bash, Python, jq, curl
and openssl.
"""

import hashlib
import http.server
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
# darkbloom-sandbox's public/darkbloom-actions/.github/workflows/route.yml, last
# changed in c79f29871 (origin/master 7fb82ec52, 2026-11-20). Update the copy
# only by copying a newer upstream file, and this hash with it.
UPSTREAM_ROUTER_SHA256 = "7d3afe26edc42b4c21f3e034cd874fc39173685cb6471e3e5cfe1ca3956c5ecf"
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
# The release's SDK qualification (release-qualify.yml). Each release caller
# calls it from one job, `qualify`, with no secrets, before its credentialed
# release-provider.yml call. Its five shards ask on one lane, except in a tag
# (prod) run: recovery of a failed tag run takes its retained unsigned artifact
# by name (scripts/provider_release_resume/identity.py).
RELEASE_QUALIFY = "release-qualify.yml"
RELEASE_QUALIFY_COUNT = "${{ github.ref_type != 'tag' && 5 || 0 }}"
RELEASE_CALLERS = ("release-dev-branch.yml", "release-swift.yml")
DISPATCH = "${{ github.event_name == 'workflow_dispatch' && 1 || 0 }}"
# Every routed job: (profile, fallback label, count expression, placement,
# size) of each lane it reads. Every lane names its count, `balanced` and its
# size (David, 2026-11-20): a lane without a size gets the approval's pinned
# size for its profile. Every Linux lane asks for 4x16, the class of its
# 4-vCPU Blacksmith fallback. The desktop package takes 60-241 s on a 12-vCPU
# Mac (runs 42924473533 to 43422901730), so it asks for the smallest; each SDK
# 27 warm lane is over 10 minutes even on 12x32 (release p90 1,363 s,
# qualification p90 2,180 s), so it keeps 12x32.
ROUTED = {
    "docs-impact.yml": {
        "commit-signatures": ("linux_arm64", LINUX_FALLBACK, "1", "balanced", "4x16"),
        "docs-impact": ("linux_arm64", LINUX_FALLBACK, "1", "balanced", "4x16"),
    },
    "landing.yml": {"check": ("linux_arm64", LINUX_FALLBACK, "1", "balanced", "4x16")},
    "desktop.yml": {
        "frontend": ("linux_arm64", LINUX_FALLBACK, "1", "balanced", "4x16"),
        "desktop-package": ("macos_arm64", MACOS_FALLBACK, DISPATCH, "balanced", "4x16"),
    },
    "provider-release-cache.yml": {"warm": ("macos_arm64", MACOS_FALLBACK, PULL_REQUEST_WARM, "balanced", "12x32")},
    # SDK 27 qualification, sized as the warm's qualification lane.
    RELEASE_QUALIFY: {"qualify-sdk-shard": ("macos_arm64", MACOS_FALLBACK, RELEASE_QUALIFY_COUNT, "balanced", "12x32")},
}
# A routed job whose lane is not its job name.
LANE_NAME = {"qualify-sdk-shard": "release-qualify"}
# Routed jobs whose lanes ask by event rather than by their job's `if`: PR
# warming only, and release qualification except in tag runs.
EVENT_COUNTED = {"warm", "qualify-sdk-shard"}
# CI: the callers run provider-plan.yml, whose route job is the run's only
# route request (the plane routes a run attempt once), with the caller's own
# Linux lanes. Every macOS job (provider-tests.yml) reads `inputs.routes`; CI
# (master)'s Release Integrity and Docs Lint read the plan's output.
CALLERS = ("ci-dev.yml", "ci-master.yml")
PLAN = "provider-plan.yml"
COMPONENT = "${{{{ needs.components.outputs.{} == 'true' && {} || 0 }}}}"
# The sizes the sandbox plane signs (<vCPUs>x<GiB>) for each profile.
VALID_SIZES = {"linux_arm64": {"4x16"}, "macos_arm64": {"4x16", "4x24", "8x16", "12x32"}}


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


# Every routed macOS job of CI: lane -> (count, size), each size from the
# job's sampled memory (provider-plan.yml); every lane is `balanced`. The 15
# blocking test jobs come first, critical path first. Shards share the lanes
# test-cluster-2 (runtime shards 2, 3, 6 and 7), test-cluster-3 (runtime
# shards 4 and 5) and test-cluster-focused, lanes the approval names; Provider
# Gates reads test-provider-gates. Then the build jobs and the release build
# checks, then the 3 non-blocking GPU shards.
PLAN_LANES = {
    "test-cluster-2": (requested("cluster", 4), "4x24"),
    "test-cluster-3": (requested("cluster", 2), "4x16"),
    "test-cluster-focused": (requested("cluster", 2), "4x16"),
    "test-provider-2": (requested("provider"), "4x24"),
    "test-cluster-1": (requested("cluster"), "4x24"),
    "test-provider-1": (requested("provider"), "12x32"),
    "test-provider-3": (requested("provider"), "4x24"),
    "test-provider-4": (requested("provider"), "4x24"),
    "test-provider-5": (requested("provider"), "4x24"),
    "test-provider-gates": (requested("provider"), "4x24"),
    "build-cluster": (requested("cluster"), "8x16"),
    # Also on a dev push that runs no provider test but moves the build
    # cache's dependency tier: the build saves its caches, and no test job runs.
    "build-provider": ("${{ (needs.components.outputs.provider == 'true' || "
                       "needs.components.outputs.warm_provider_cache == 'true') && 1 || 0 }}", "12x32"),
    "cluster-release-checks": (requested("cluster"), "8x16"),
    "test-cluster-gpu-1": (requested("cluster_gpu"), "4x24"),
    "test-cluster-gpu-2": (requested("cluster_gpu"), "4x24"),
    "test-cluster-gpu-3": (requested("cluster_gpu"), "4x24"),
}
# The plan's own Linux lane, before the macOS lanes: Check the CI plans
# (provider-tests.yml's ci-plan-checks) on every run that runs the test jobs.
# Its fallback is the GitHub-hosted runner it ran on before it was routed.
HOSTED = "ubuntu-24.04"
PLAN_LINUX_LANES = {"ci-plan-checks": ("${{ inputs.run_tests && 1 || 0 }}", "4x16")}
# The lanes of the blocking test jobs.
BLOCKING_TESTS = [lane for lane in PLAN_LANES if lane.startswith("test-") and "-gpu-" not in lane]
MASTER_LINUX_LANES = (f"release-integrity linux_arm64 {LINUX_FALLBACK} 1 balanced 4x16",
                      f"docs linux_arm64 {LINUX_FALLBACK} 1 balanced 4x16")
# (workflow, job): the expression its runs-on reads.
CI_ROUTED = {
    ("provider-tests.yml", "test-provider"): "inputs.routes", ("provider-tests.yml", "test-cluster"): "inputs.routes",
    ("provider-tests.yml", "test-provider-gates"): "inputs.routes",
    ("provider-tests.yml", "test-cluster-focused"): "inputs.routes",
    ("provider-tests.yml", "build-cluster"): "inputs.routes", ("provider-tests.yml", "build-provider"): "inputs.routes",
    ("provider-tests.yml", "cluster-release-checks"): "inputs.routes",
    ("provider-tests.yml", "test-cluster-gpu"): "inputs.routes",
    ("provider-tests.yml", "ci-plan-checks"): "inputs.routes",
    ("ci-master.yml", "release-integrity"): "needs.plan.outputs.routes",
    ("ci-master.yml", "docs"): "needs.plan.outputs.routes",
}
# darkbloom-sandbox's GitHub-side watchdog (public/darkbloom-actions
# .github/workflows/watchdog.yml at d6d257c2), hardened to preserve partial runs.
WATCHDOG = "darkbloom-watchdog.yml"
# Credentialed, release, review or publication workflows keep literal runners.
# So does Nightly Linear Package until d-inference's sandbox network template
# allows PyPI: on a Darkbloom Linux sandbox, setup-python's pip gets 502 from
# the sandbox proxy (run 44696912484).
UNROUTED = ("nightly-linear-package.yml", "release-swift.yml", "release-provider.yml", "release-dev-branch.yml",
            "release-desktop.yml", "provider-signing-validation.yml", "register-model.yml",
            "threat-model-review.yml", "bedrock-smoke.yml", "claude.yml", "codex.yml",
            "ci-dev-nightly.yml")
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

    The host's proxy, `CURL_*`, `SSL_CERT_*` and GitHub OIDC
    (`ACTIONS_ID_TOKEN_REQUEST_*`) settings are dropped, so only `variables`
    choose the plane, its CA and whether a token can be requested. Returns the
    process, every `routes` output the step wrote and its step summary.
    """
    output, summary = work / "output", work / "summary"
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("CURL_", "SSL_CERT_", "ACTIONS_ID_TOKEN_REQUEST_"))
                   and key.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    environment.update(NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost",
                       GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
    environment.update(variables)
    result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                            cwd=work, env=environment, capture_output=True, text=True, timeout=160)
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
        return [f"{name}-{shard}" for shard in matrix_shards(job)]
    return [LANE_NAME.get(name, name)]


def requested_lanes(workflow, routed):
    """Return {lane: (profile, fallback, count, placement, size)} that the caller's route job must request."""
    return {lane: lane_spec for name, lane_spec in routed.items()
            for lane in job_lanes(name, workflow[name])}


def lane_lines(route_job):
    """Return the caller's literal `lanes` block lines, before expression evaluation."""
    return literal_block(route_job, "lanes", 6).splitlines()


def route_lanes(route_job):
    """Parse the caller's `lanes` lines into {lane: (profile, fallback, count, placement, size)}."""
    return route_lanes_text(lane_lines(route_job))


# `<lane> <profile> <fallback> [count] [placement] [shape]`; a count can be one
# `${{ ... }}` expression.
LANE_LINE = re.compile(r"(\S+) (\S+) (\S+)(?: (\$\{\{ .+? \}\}|\S+))?(?: (\S+))?(?: (\S+))?")


def route_lanes_text(lines):
    lanes = {}
    for line in lines:
        lane, profile, fallback, count, placement, size = LANE_LINE.fullmatch(line).groups()
        lanes[lane] = (profile, fallback, count, placement, size)
    return lanes


def plan_count(condition, jobs):
    """The plan's count for a job of provider-tests.yml: its jobs exactly when its `if` holds.

    The job's inputs, its `skip` included, are the plan job's outputs.
    """
    inner = condition.removeprefix("${{ ").removesuffix(" }}")
    inner = inner.replace("inputs.", "needs.components.outputs.")
    # `a || b && N` would evaluate to `a`; group an alternative.
    if "||" in inner:
        inner = f"({inner})"
    return f"${{{{ {inner} && {jobs} || 0 }}}}"


def plan_lanes_text(outcome="1"):
    """CI's macOS lane lines from provider-plan.yml, every count evaluated one way."""
    route = jobs((WORKFLOWS / PLAN).read_text())["route"]
    macos = [line for line in lane_lines(route)[1:] if line.split()[0] not in PLAN_LINUX_LANES]
    return evaluate_counts("\n".join(macos) + "\n", outcome)


def sized(size, labels=MACOS, cheapest=False):
    """The Darkbloom labels of a lane sent with this size (and `cheapest`)."""
    return [*labels[:-1], f"{labels[-1]}-{size}" + ("-cheapest" if cheapest else "")]


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
    """Loopback plane answering each POST with the next scripted (status, body, delay).

    A GET stands in for GitHub's OIDC token endpoint: it is recorded in
    `token_requests` and answered with (status, body) `token_reply`.
    """

    def __init__(self, certificate, key, replies, tls=True, token_reply=(200, {"value": "a.b.c"})):
        self.requests = []
        self.token_requests = []
        self.released = threading.Event()
        plane = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                plane.token_requests.append({"path": self.path, "headers": dict(self.headers)})
                status, payload = token_reply
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                plane.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                entry = replies[min(len(plane.requests), len(replies)) - 1]
                status, payload, delay = entry[:3]
                extra_headers = entry[3] if len(entry) > 3 else {}
                if delay and plane.released.wait(delay):
                    return
                data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    for header_name, header_value in extra_headers.items():
                        self.send_header(header_name, str(header_value))
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

    def plane(self, *replies, tls=True, **options):
        return Plane(self.certificate, self.key, replies or ((200, GRANT_ALL, 0),), tls=tls, **options)

    def route(self, plane_url, routing="on", lanes=LANES, trust=True, **context):
        if routing == "on" and not plane_url:
            raise AssertionError("Tests must never fall through to the production plane")
        variables = dict(LANES=lanes, ROUTING=routing, PLANE_URL=plane_url, REPOSITORY="Layr-Labs/d-inference",
                         EVENT_NAME="push", HEAD_REPOSITORY="", RUN_ID="40408691758", RUN_ATTEMPT="2")
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
                    self.assertIn("| `warm` | macos_arm64 | 2 | `blacksmith-12vcpu-macos-27` "
                                  "| fallback: routing is off |", summary)
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
                self.assertIn("| `warm` | macos_arm64 | 2 | `self-hosted, macOS, ARM64, darkbloom-macos-arm64` "
                              "| darkbloom: granted |", summary)
                # A public repository's calling job grants no id-token: no
                # token is requested and none is sent.
                self.assertNotIn("Authorization", request["headers"])
                self.assertIn("GitHub Actions OIDC token: not available", result.stdout)

    def test_run_scoped_labels_of_this_run_are_used_and_asked_for(self):
        # The request opts in to run-scoped labels; the plane then names this
        # run's ID in the last label, after any size and placement. Another
        # run's ID, a scope before or without the size or placement, or on an
        # extra label, keeps the fallback.
        scoped_linux = LINUX[:-1] + [LINUX[-1] + "-run-40408691758"]
        scoped_macos = MACOS[:-1] + [MACOS[-1] + "-run-40408691758"]
        sized = MACOS[:-1] + [MACOS[-1] + "-4x24-run-40408691758"]
        cheapest = LINUX[:-1] + [LINUX[-1] + "-4x16-cheapest-run-40408691758"]
        cases = {
            "this run": ("release-integrity linux_arm64 %s\n" % LINUX_FALLBACK,
                         {"release-integrity": {"target": "darkbloom", "runs_on": scoped_linux}},
                         {"release-integrity": scoped_linux}),
            "this run, sized": ("test-cluster-1 macos_arm64 %s 1 balanced 4x24\n" % MACOS_FALLBACK,
                                {"test-cluster-1": {"target": "darkbloom", "runs_on": sized}},
                                {"test-cluster-1": sized}),
            "another run": ("release-integrity linux_arm64 %s\n" % LINUX_FALLBACK,
                            {"release-integrity": {"target": "darkbloom",
                                                   "runs_on": LINUX[:-1] + [LINUX[-1] + "-run-1"]}},
                            {"release-integrity": LINUX_FALLBACK}),
            "scope before the size": ("test-cluster-1 macos_arm64 %s 1 balanced 4x24\n" % MACOS_FALLBACK,
                                      {"test-cluster-1": {"target": "darkbloom", "runs_on":
                                          MACOS[:-1] + [MACOS[-1] + "-run-40408691758-4x24"]}},
                                      {"test-cluster-1": MACOS_FALLBACK}),
            "scope without the size": ("test-cluster-1 macos_arm64 %s 1 balanced 4x24\n" % MACOS_FALLBACK,
                                       {"test-cluster-1": {"target": "darkbloom", "runs_on": scoped_macos}},
                                       {"test-cluster-1": MACOS_FALLBACK}),
            "scope on an extra label": ("release-integrity linux_arm64 %s\n" % LINUX_FALLBACK,
                                        {"release-integrity": {"target": "darkbloom",
                                                               "runs_on": LINUX + [scoped_linux[-1]]}},
                                        {"release-integrity": LINUX_FALLBACK}),
            "this run, sized, cheapest": ("check linux_arm64 %s 1 cheapest 4x16\n" % LINUX_FALLBACK,
                                          {"check": {"target": "darkbloom", "runs_on": cheapest}},
                                          {"check": cheapest}),
            "scope before the placement": ("check linux_arm64 %s 1 cheapest 4x16\n" % LINUX_FALLBACK,
                                           {"check": {"target": "darkbloom", "runs_on": LINUX[:-1] + [
                                               LINUX[-1] + "-4x16-run-40408691758-cheapest"]}},
                                           {"check": LINUX_FALLBACK}),
        }
        for name, (lanes, decisions, expected) in cases.items():
            with self.subTest(case=name), self.plane((200, reply(**decisions), 0)) as plane:
                result, routes, _ = self.route(plane.url, lanes=lanes)
                self.assertRoutes(result, routes, expected)
                self.assertEqual(plane.requests[0]["headers"]["X-Darkbloom-Run-Scoped-Labels"], "1")

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

    def test_http_errors_fall_back_and_only_transient_errors_retry(self):
        for status, attempts in ((500, 2), (503, 2), (429, 2), (408, 2),
                                 (400, 1), (403, 1), (404, 1), (201, 1), (302, 1)):
            with self.subTest(status=status), self.plane((status, GRANT_ALL, 0)) as plane:
                result, routes, summary = self.route(plane.url, MAX_ATTEMPTS="2")
                self.assertRoutes(result, routes)
                self.assertEqual(len(plane.requests), attempts)
                self.assertIn(f"plane request failed (HTTP {status})", summary)

    def test_default_two_attempts_and_exponential_backoff_with_retry_after(self):
        # Default MAX_ATTEMPTS is 2 (no caller passes max-attempts): one retry
        # after a 1-second pause, then the fallback.
        with self.plane((503, {"error": "service_stopping"}, 0),
                        (503, {"error": "service_stopping"}, 0),
                        (200, GRANT_ALL, 0)) as plane:
            started = time.monotonic()
            result, routes, summary = self.route(plane.url, MAX_ATTEMPTS="")
            elapsed = time.monotonic() - started
        self.assertRoutes(result, routes)
        self.assertEqual(len(plane.requests), 2)
        self.assertGreaterEqual(elapsed, 1)
        self.assertIn("plane request failed (HTTP 503)", summary)
        # With more attempts, transient 503/429 bursts recover without
        # spilling onto paid fallback runners.
        with self.plane((503, {"error": "service_stopping"}, 0),
                        (429, {"error": "rate_limited"}, 0, {"Retry-After": "1"}),
                        (503, {"error": "request_deadline"}, 0),
                        (200, GRANT_ALL, 0)) as plane:
            result, routes, _ = self.route(plane.url, MAX_ATTEMPTS="6")
        self.assertRoutes(result, routes, GRANTED)
        self.assertEqual(len(plane.requests), 4)
        self.assertIn('"error":"service_stopping"', result.stdout)
        self.assertIn('"retry_after_seconds":1', result.stdout)
        # Explicit MAX_ATTEMPTS caps retries, and invalid values fail configuration.
        with self.plane((503, {}, 0)) as plane:
            result, routes, summary = self.route(plane.url, MAX_ATTEMPTS="3")
        self.assertRoutes(result, routes)
        self.assertEqual(len(plane.requests), 3)
        self.assertIn("plane request failed (HTTP 503)", summary)
        for bad in ("0", "10", "-1", "six"):
            with self.subTest(max_attempts=bad), self.plane() as plane:
                result, routes, _ = self.route(plane.url, MAX_ATTEMPTS=bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error title=Darkbloom route configuration::", result.stdout)
                self.assertIsNone(routes)
            self.assertEqual(plane.requests, [])

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
            result, routes, summary = self.route(plane.url, MAX_ATTEMPTS="2")
        self.assertRoutes(result, routes)
        self.assertEqual(len(plane.requests), 2)
        self.assertIn("HTTP 000", summary)

    def test_unresponsive_plane_times_out_into_fallbacks(self):
        with self.plane((200, GRANT_ALL, 30)) as plane:
            started = time.monotonic()
            result, routes, summary = self.route(plane.url, MAX_ATTEMPTS="2")
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
        result, routes, _ = self.route(closed, MAX_ATTEMPTS="2")
        self.assertRoutes(result, routes)
        # Certificate verification stays on: an untrusted plane is never asked.
        with self.plane() as plane:
            result, routes, _ = self.route(plane.url, trust=False, MAX_ATTEMPTS="2")
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
        many = "".join(f"lane-{index} linux_arm64 {LINUX_FALLBACK}\n" for index in range(33))
        invalid = ("", "\n \n", f"docs linux_x64 {LINUX_FALLBACK}", "docs linux_arm64",
                   f"docs linux_arm64 {LINUX_FALLBACK} -1", f"docs linux_arm64 {LINUX_FALLBACK} 1.5",
                   f"docs linux_arm64 {LINUX_FALLBACK} 17", f"docs linux_arm64 {LINUX_FALLBACK} 100",
                   f"docs linux_arm64 {LINUX_FALLBACK} 01", "docs linux_arm64 label;id",
                   f"docs linux_arm64 {LINUX_FALLBACK} 1 balanced 4x16 extra",
                   # Lane names: lowercase letters, digits and dashes, at most 63.
                   f"docs.lint linux_arm64 {LINUX_FALLBACK}", f"Docs linux_arm64 {LINUX_FALLBACK}",
                   f"docs_lint linux_arm64 {LINUX_FALLBACK}", f"-docs linux_arm64 {LINUX_FALLBACK}",
                   f"{'d' * 64} linux_arm64 {LINUX_FALLBACK}",
                   f"docs linux_arm64 {LINUX_FALLBACK}\ndocs macos_arm64 {MACOS_FALLBACK}",
                   # At most 32 lanes.
                   many,
                   # Placement: balanced or cheapest, before the size. The old
                   # grammar's size in the fifth field is a bad placement.
                   f"docs linux_arm64 {LINUX_FALLBACK} 1 extra", f"docs linux_arm64 {LINUX_FALLBACK} 1 Balanced",
                   f"docs linux_arm64 {LINUX_FALLBACK} 1 4x16", f"mac macos_arm64 {MACOS_FALLBACK} 1 12x32",
                   f"mac macos_arm64 {MACOS_FALLBACK} 1 12x32 required",
                   # The old `required` flag is a seventh field now.
                   f"mac macos_arm64 {MACOS_FALLBACK} 1 balanced 12x32 required",
                   # Sizes: the plane's grammar and bounds, on either profile.
                   *(f"{lane} {profile} {fallback} 1 balanced {size}"
                     for lane, profile, fallback in (("mac", "macos_arm64", MACOS_FALLBACK),
                                                     ("docs", "linux_arm64", LINUX_FALLBACK))
                     for size in ("4X24", "04x24", "4x024", "0x16", "4x0", "4x", "x24", "4x24x1", "4*24",
                                  "4x24-disk-50", "4 x24", "257x16", "4x1025", "1000x16", "4x10000")))
        with self.plane() as plane:
            for lanes in invalid:
                with self.subTest(lanes=lanes):
                    result, routes, _ = self.route(plane.url, lanes=lanes)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("::error title=Darkbloom route configuration::", result.stdout)
                    self.assertIsNone(routes)
            for value in ("yes", "TRUE", "1", "on"):
                with self.subTest(require_darkbloom=value):
                    result, routes, _ = self.route(plane.url, REQUIRE_DARKBLOOM=value)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("::error title=Darkbloom route configuration::invalid require-darkbloom", result.stdout)
                    self.assertIsNone(routes)
        self.assertEqual(plane.requests, [])
        # The bounds themselves are accepted: 32 lanes, a count of 16, a
        # 63-character name, 256 vCPUs and 1024 GiB.
        bounds = ("".join(many.splitlines(keepends=True)[2:])
                  + f"{'d' * 63} macos_arm64 {MACOS_FALLBACK} 16 cheapest 256x1024\n")
        result, routes, _ = self.route("", routing="off", lanes=bounds)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(routes), 32)

    def test_every_plan_lane_asks_for_its_size_and_takes_only_those_labels(self):
        lanes = plan_lanes_text()
        # Every lane asks for its size and takes only its sized labels. The
        # plane's fallback reasons reach the log and the summary.
        decisions = {lane: {"target": "darkbloom", "runs_on": sized(size)} for lane, (_, size) in PLAN_LANES.items()}
        reasons = {"test-cluster-1": "shape_not_signed", "build-provider": "unsupported_runner_class",
                   "cluster-release-checks": "image_not_available", "test-cluster-focused": "lane_not_enabled",
                   "test-provider-2": "profile_degraded", "test-provider-1": "unavailable"}
        decisions.update({lane: {"target": "fallback", "reason": reason} for lane, reason in reasons.items()})
        with self.plane((200, reply(**decisions), 0)) as plane:
            result, routes, summary = self.route(plane.url, lanes=lanes)
        self.assertRoutes(result, routes, {lane: MACOS_FALLBACK if lane in reasons else sized(size)
                                           for lane, (_, size) in PLAN_LANES.items()})
        request, = plane.requests
        # `balanced` is the default placement, so the request does not name it.
        self.assertEqual(json.loads(request["body"])["lanes"],
                         [{"lane": lane, "profile": "macos_arm64", "count": lane_jobs(count), "shape": size}
                          for lane, (count, size) in PLAN_LANES.items()])
        for lane, reason in reasons.items():
            count, _ = PLAN_LANES[lane]
            self.assertIn(f"{lane}: {MACOS_FALLBACK} (plane: {reason})\n", result.stdout)
            self.assertIn(f"| `{lane}` | macos_arm64 | {lane_jobs(count)} | `{MACOS_FALLBACK}` "
                          f"| fallback: plane: {reason} |", summary)
        self.assertIn("| `build-cluster` | macos_arm64 | 1 | `self-hosted, macOS, ARM64, "
                      "darkbloom-macos-arm64-8x16` | darkbloom: granted |", summary)

    def test_a_sized_lane_takes_only_the_labels_of_its_size_and_placement(self):
        def grant(lane, labels):
            return reply(**{lane: {"target": "darkbloom", "runs_on": labels}})

        cases = [
            ("test-cluster-1", f"test-cluster-1 macos_arm64 {MACOS_FALLBACK} 1 balanced 4x24\n",
             MACOS_FALLBACK, sized("4x24"), {
                "no size": MACOS, "other size": sized("12x32"), "upper case": sized("4X24"),
                "cheapest": sized("4x24", cheapest=True),
                "with a disk": [*MACOS[:-1], f"{MACOS[-1]}-4x24-disk-50"],
                "size label added": [*MACOS, f"{MACOS[-1]}-4x24"], "size label alone": [f"{MACOS[-1]}-4x24"],
                "linux": sized("4x24", LINUX)}),
            ("check", f"check linux_arm64 {LINUX_FALLBACK} 1 balanced 4x16\n",
             LINUX_FALLBACK, sized("4x16", LINUX), {
                "no size": LINUX, "other size": sized("4x24", LINUX), "cheapest": sized("4x16", LINUX, True),
                "macos": sized("4x16")}),
            ("check", f"check linux_arm64 {LINUX_FALLBACK} 1 cheapest 4x16\n",
             LINUX_FALLBACK, sized("4x16", LINUX, True), {
                "balanced": sized("4x16", LINUX), "no size": [*LINUX[:-1], f"{LINUX[-1]}-cheapest"],
                "placement before the size": [*LINUX[:-1], f"{LINUX[-1]}-cheapest-4x16"]}),
            ("check", f"check linux_arm64 {LINUX_FALLBACK} 1 cheapest\n",
             LINUX_FALLBACK, [*LINUX[:-1], f"{LINUX[-1]}-cheapest"], {
                "balanced": LINUX, "sized": sized("4x16", LINUX, True)}),
        ]
        for lane, lanes, fallback, expected, invalid in cases:
            for name, labels in invalid.items():
                with self.subTest(lanes=lanes, decision=name), self.plane((200, grant(lane, labels), 0)) as plane:
                    result, routes, summary = self.route(plane.url, lanes=lanes)
                    self.assertRoutes(result, routes, {lane: fallback})
                    self.assertIn("plane decision is missing or invalid", summary)
            with self.subTest(lanes=lanes, decision="exact"), self.plane((200, grant(lane, expected), 0)) as plane:
                result, routes, _ = self.route(plane.url, lanes=lanes)
                self.assertRoutes(result, routes, {lane: expected})
            # The request names a placement only when it is `cheapest`, and a
            # shape only when the lane has one.
            _, profile, _, _, placement, *shape = lanes.split()
            self.assertEqual(json.loads(plane.requests[0]["body"])["lanes"],
                             [{"lane": lane, "profile": profile, "count": 1,
                               **({"placement": "cheapest"} if placement == "cheapest" else {}),
                               **({"shape": shape[0]} if shape else {})}])

    def test_require_darkbloom_fails_only_when_a_requested_lane_falls_back(self):
        # Granted: the routes are written and the job passes.
        with self.plane() as plane:
            result, routes, _ = self.route(plane.url, REQUIRE_DARKBLOOM="true")
        self.assertRoutes(result, routes, GRANTED)
        # `docs` (count 0) is not requested, so its fallback never fails the job.
        self.assertEqual(routes["docs"], LINUX_FALLBACK)
        # A requested lane that falls back fails the job before any routes are
        # written; while it is false (the default), the same run passes.
        partial = reply(**{**GRANT_ALL["lanes"], "warm": {"target": "fallback", "reason": "busy"}})
        for name, replies, routing in (("plane fallback", ((200, partial, 0),), "on"),
                                       ("plane error", ((500, {}, 0),), "on"),
                                       ("routing off", ((200, GRANT_ALL, 0),), "off")):
            with self.subTest(case=name), self.plane(*replies) as plane:
                result, routes, _ = self.route(plane.url, routing=routing, REQUIRE_DARKBLOOM="true")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("::error title=Darkbloom route required::require-darkbloom is true but lane(s) "
                              "fell back: ", result.stdout)
                self.assertIsNone(routes)
                for value in ("false", ""):
                    result, routes, _ = self.route(plane.url, routing=routing, REQUIRE_DARKBLOOM=value)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIsNotNone(routes)

    def test_a_job_that_grants_id_token_sends_this_runs_oidc_token(self):
        # A private repository's calling job grants `id-token: write`; the
        # runner then sets both request variables. The token is requested for
        # the plane's origin, masked, and sent only to the plane.
        token = "aGVhZGVy.cGF5bG9hZA.c2ln"
        with self.plane(token_reply=(200, {"value": token})) as plane:
            request_url = f"{plane.url}/token?api-version=2.0"
            result, routes, summary = self.route(plane.url, ACTIONS_ID_TOKEN_REQUEST_URL=request_url,
                                                 ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token")
        self.assertRoutes(result, routes, GRANTED)
        asked, = plane.token_requests
        port = plane.url.rsplit(":", 1)[1]
        self.assertEqual(asked["path"], f"/token?api-version=2.0&audience=https%3A%2F%2F127.0.0.1%3A{port}")
        self.assertEqual(asked["headers"]["Authorization"], "Bearer request-token")
        request, = plane.requests
        self.assertEqual(request["headers"]["Authorization"], f"Bearer {token}")
        self.assertIn(f"::add-mask::{token}\n", result.stdout)
        self.assertEqual(result.stdout.count(token), 1)
        self.assertNotIn(token, summary)
        self.assertIn("with this run's OIDC token", summary)
        # A malformed token reply sends the request without a token.
        for name, token_reply in (("malformed", (200, {"value": "not a token"})), ("error", (403, {}))):
            with self.subTest(token=name), self.plane(token_reply=token_reply) as plane:
                result, routes, summary = self.route(plane.url, ACTIONS_ID_TOKEN_REQUEST_URL=f"{plane.url}/token?x=1",
                                                     ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token")
                self.assertRoutes(result, routes, GRANTED)
                self.assertNotIn("Authorization", plane.requests[0]["headers"])
                self.assertIn("No OIDC token could be requested", summary)

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
        self.assertEqual(row.count("|"), 6)

    def test_release_qualification_lane_falls_back_until_the_approval_lists_it(self):
        # The release asks for its five shards on one lane. Until the sandbox
        # approval lists lane release-qualify, the plane answers
        # lane_not_enabled and every shard keeps Blacksmith. A tag run asks
        # for nothing.
        route = jobs((WORKFLOWS / RELEASE_QUALIFY).read_text())["route"]
        text = "\n".join(lane_lines(route)) + "\n"
        refused = reply(**{"release-qualify": {"target": "fallback", "reason": "lane_not_enabled"}})
        with self.plane((200, refused, 0)) as plane:
            result, routes, summary = self.route(plane.url, lanes=evaluate_counts(text, "1"))
            tag, tag_routes, tag_summary = self.route(plane.url, lanes=evaluate_counts(text, "0"))
        self.assertRoutes(result, routes, {"release-qualify": MACOS_FALLBACK})
        request, = plane.requests
        # `balanced` is the default placement, so the request does not name it.
        self.assertEqual(json.loads(request["body"])["lanes"],
                         [{"lane": "release-qualify", "profile": "macos_arm64", "count": 5, "shape": "12x32"}])
        self.assertIn(f"| `release-qualify` | macos_arm64 | 5 | `{MACOS_FALLBACK}` "
                      "| fallback: plane: lane_not_enabled |", summary)
        self.assertRoutes(tag, tag_routes, {"release-qualify": MACOS_FALLBACK})
        self.assertIn("No lane has jobs to run. No request was sent.", tag_summary)


class RouteWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.texts = {path.name: path.read_text() for path in WORKFLOWS.glob("*.yml")}

    def test_every_workflow_is_classified(self):
        self.assertEqual(set(self.texts), set(ROUTED) | set(UNROUTED) | set(CALLERS) |
                         {"darkbloom-route.yml", PLAN, "provider-tests.yml", WATCHDOG})

    def test_router_is_darkbloom_sandboxs_route_workflow_byte_for_byte(self):
        self.assertEqual(hashlib.sha256(ROUTER.read_bytes()).hexdigest(), UPSTREAM_ROUTER_SHA256)

    def test_router_is_isolated_and_defaults_to_the_sandbox_plane(self):
        text = self.texts["darkbloom-route.yml"]
        header, body = text.split("\njobs:\n", 1)
        self.assertEqual(re.findall(r"(?m)^  ([a-z_]+):$", header.split("\non:\n", 1)[1]), ["workflow_call"])
        # The router declares no permissions: its job holds exactly what the
        # calling job grants, and every calling job grants `{}`
        # (test_routed_jobs_read_their_lane_and_keep_their_fallback,
        # test_ci_routes_every_job_that_runs_code_through_one_plan).
        self.assertNotRegex(text, r"(?m)^\s*permissions:")
        select, = jobs(text).values()
        self.assertEqual(job_field(select, "runs-on"), "ubuntu-24.04")
        self.assertEqual(job_field(select, "timeout-minutes"), "3")
        self.assertEqual(len(re.findall(r"(?m)^      - ", select)), 1)
        for forbidden in ("uses:", "secrets", "checkout", "${{ github.token"):
            self.assertNotIn(forbidden, body)
        self.assertIn("value: ${{ jobs.select.outputs.routes }}", header)
        self.assertIn("      routes: ${{ steps.route.outputs.routes }}\n", select)
        for name, expression in {"LANES": "inputs.lanes", "MAX_ATTEMPTS": "inputs.max-attempts",
                                 "REQUIRE_DARKBLOOM": "inputs.require-darkbloom",
                                 "ROUTING": "vars.DARKBLOOM_ROUTING",
                                 "PLANE_URL": "vars.DARKBLOOM_SANDBOX_URL", "REPOSITORY": "github.repository",
                                 "EVENT_NAME": "github.event_name",
                                 "HEAD_REPOSITORY": "github.event.pull_request.head.repo.full_name",
                                 "RUN_ID": "github.run_id", "RUN_ATTEMPT": "github.run_attempt"}.items():
            self.assertIn(f"          {name}: ${{{{ {expression} }}}}\n", select)
        self.assertIn("      max-attempts:\n", header)
        self.assertIn("        default: 2\n", header)
        self.assertIn("      require-darkbloom:\n", header)
        self.assertIn("        default: false\n", header)
        script = route_step()
        self.assertIn("max_attempts=${MAX_ATTEMPTS:-2}\n", script)
        self.assertIn("require_darkbloom=${REQUIRE_DARKBLOOM:-false}\n", script)
        self.assertIn("plane_url=${PLANE_URL:-https://api-sandbox.darkbloom.dev}\n", script)
        self.assertIn('if [ "${ROUTING:-}" != on ]; then\n', script)
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
                # Only `lanes`: the default attempts (2) and require-darkbloom (false).
                self.assertEqual(re.findall(r"(?m)^      ([a-z-]+):", route.split("\n    with:\n", 1)[1]), ["lanes"])
                self.assertEqual(route_lanes(route), requested_lanes(workflow, expected))
            for name, (_, _, count, _, _) in expected.items():
                job = workflow[name]
                with self.subTest(workflow=filename, job=name):
                    self.assertIn("route", needs(job))
                    if name in SHARDED:
                        self.assertTrue(matrix_shards(job))
                        lane = f"format('{name}-{{0}}', matrix.shard)"
                    else:
                        lane = f"'{LANE_NAME.get(name, name)}'"
                    self.assertEqual(job_field(job, "runs-on"), RUNS_ON.get(
                        name, f"${{{{ fromJSON(needs.route.outputs.routes)[{lane}] }}}}"))
                    condition = job_field(job, "if")
                    if name not in EVENT_COUNTED:
                        # A lane is requested exactly when its job runs, once per
                        # matrix entry that reads it. `!cancelled()` cannot be
                        # evaluated in the route job and is true there.
                        jobs_requested = 1 if name in SHARDED else len(matrix_shards(job)) or 1
                        expected_count = str(jobs_requested)
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
                         "${{ needs.gate.outputs.run == 'true' && (github.event_name == 'pull_request' || github.ref == 'refs/heads/master') }}")

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
        # The plan's Linux lane comes first, then every macOS lane.
        self.assertEqual(list(planned), [*PLAN_LINUX_LANES, *PLAN_LANES])
        self.assertEqual({lane: (count, size) for lane, (_, _, count, _, size) in planned.items()},
                         {**PLAN_LINUX_LANES, **PLAN_LANES})
        self.assertTrue(all(profile == "linux_arm64" and fallback == HOSTED and placement == "balanced"
                            for lane, (profile, fallback, _, placement, _) in planned.items()
                            if lane in PLAN_LINUX_LANES))
        self.assertTrue(all(profile == "macos_arm64" and fallback == MACOS_FALLBACK and placement == "balanced"
                            for lane, (profile, fallback, _, placement, _) in planned.items()
                            if lane in PLAN_LANES))
        # The callers: CI (dev) adds no lane; CI (master) adds its Linux lanes.
        # The plan's run_tests is true exactly when the caller runs `tests`,
        # so ci-plan-checks's lane asks only for a job that runs: CI (master)
        # passes the tests job's guard; CI (dev) runs its plan only under that
        # guard and keeps run_tests's default, true.
        self.assertRegex(self.texts[PLAN], r"(?m)^      run_tests:\n(?:        .+\n)*?        default: true\n")
        for filename in CALLERS:
            workflow = jobs(self.texts[filename])
            with self.subTest(workflow=filename):
                self.assertEqual(job_field(workflow["plan"], "uses"), f"./.github/workflows/{PLAN}")
                self.assertEqual(job_field(workflow["tests"], "uses"), "./.github/workflows/provider-tests.yml")
                self.assertEqual(needs(workflow["tests"]), ["plan"])
                self.assertNotIn("darkbloom-route.yml", self.texts[filename])
                guard = re.fullmatch(r"\$\{\{ !cancelled\(\) && \((.+)\) \}\}", job_field(workflow["tests"], "if"))
                self.assertIsNotNone(guard)
                run_tests = re.findall(r"(?m)^      run_tests: (.+)$", workflow["plan"])
                if filename == "ci-dev.yml":
                    self.assertEqual(job_field(workflow["plan"], "if"), f"${{{{ {guard.group(1)} }}}}")
                    self.assertEqual(run_tests, [])
                else:
                    self.assertIsNone(job_field(workflow["plan"], "if"))
                    self.assertEqual(run_tests, [f"${{{{ {guard.group(1)} }}}}"])
        self.assertEqual(set(jobs(self.texts["ci-dev.yml"])), {"unlabel", "plan", "tests"})
        self.assertNotIn("linux_lanes", self.texts["ci-dev.yml"])
        self.assertEqual(set(jobs(self.texts["ci-master.yml"])), {"unlabel", "plan", "tests", "release-integrity", "docs"})
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
                self.assertEqual(job_field(job, "runs-on"), f"${{{{ {routed} }}}}")
                # A lane is requested exactly when its job runs; a shared lane
                # for every job of its matrix that reads it.
                if name in PLAN_LINUX_LANES:
                    # It runs on every run of the test jobs, so it has no
                    # `if`; its lane asks on run_tests, which the callers set
                    # exactly then (above).
                    self.assertIsNone(job_field(job, "if"))
                elif filename == "provider-tests.yml":
                    for each in job_lanes(name, job):
                        if name in LANE_MATRIX:
                            jobs_requested = matrix_lanes(job).count(each)
                        else:
                            jobs_requested = 1 if name in SHARDED else len(matrix_shards(job)) or 1
                        self.assertEqual(PLAN_LANES[each][0], plan_count(job_field(job, "if"), jobs_requested))
        self.assertEqual(read, set(PLAN_LANES) | set(PLAN_LINUX_LANES) | {line.split()[0] for line in MASTER_LINUX_LANES})
        # The router accepts both callers' lane sets, with every count either
        # way.
        script = route_step()
        for linux in ("", "\n".join(MASTER_LINUX_LANES)):
            text = "\n".join([linux, *lane_lines(route)[1:]]) + "\n"
            for outcome in ("1", "0"):
                with self.subTest(linux=bool(linux), requested=outcome), tempfile.TemporaryDirectory() as work:
                    result, routes, _ = run_route_step(
                        script, Path(work), LANES=evaluate_counts(text, outcome), ROUTING="", PLANE_URL="",
                        EVENT_NAME="push", HEAD_REPOSITORY="", REPOSITORY="Layr-Labs/d-inference", RUN_ID="1",
                        RUN_ATTEMPT="1")
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    expected = {lane: MACOS_FALLBACK for lane in PLAN_LANES}
                    expected.update({lane: HOSTED for lane in PLAN_LINUX_LANES})
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
                        self.assertIn(name, ("commit", "components", "provider-test-gate", "unlabel"))

    def test_every_lane_in_every_workflow_names_a_signed_size(self):
        # David, 2026-11-20: every lane has an assigned size, so none falls
        # back to the approval's pinned size for its profile, which can be the
        # largest. Every lane in any workflow, Linux or macOS, CI (master)'s
        # `linux_lanes` input included, names its count, `balanced` and a
        # size its profile signs: 4x16 on Linux; 4x16, 4x24, 8x16 or 12x32 on
        # macOS.
        route = "./.github/workflows/darkbloom-route.yml"
        checked = 0
        for filename, text in self.texts.items():
            if "\njobs:\n" not in text:
                continue
            blocks = []
            for job in jobs(text).values():
                if job_field(job, "uses") == route:
                    blocks.append(lane_lines(job))
                if "      linux_lanes: |\n" in job:
                    blocks.append(literal_block(job, "linux_lanes", 6).splitlines())
            for line in (line for block in blocks for line in block if line.strip() and not line.startswith("${{")):
                lane, profile, _, count, placement, size = LANE_LINE.fullmatch(line).groups()
                with self.subTest(workflow=filename, lane=lane):
                    self.assertIn(profile, VALID_SIZES)
                    self.assertIsNotNone(count)
                    self.assertEqual(placement, "balanced")
                    self.assertIn(size, VALID_SIZES[profile])
                checked += 1
        # The 17 plan lanes (test-provider-gates and ci-plan-checks among
        # them), CI (master)'s 2 Linux lanes and the 7 lanes of the other
        # callers (release-qualify.yml's among them).
        self.assertEqual(checked, 26)

    def test_ci_sizes_every_routed_macos_job(self):
        sizes = {size for _, size in PLAN_LANES.values()}
        self.assertLessEqual(sizes, VALID_SIZES["macos_arm64"])
        # 21 macOS jobs ask, each with its size: the 15 blocking test jobs
        # (Provider Gates among them), the 2 build jobs and the release build
        # checks, and the 3 GPU shards.
        self.assertEqual(sum(lane_jobs(count) for count, _ in PLAN_LANES.values()), 21)
        self.assertEqual(sum(lane_jobs(PLAN_LANES[lane][0]) for lane in BLOCKING_TESTS), 15)
        # The lane table lists the blocking test lanes first, then the build
        # lanes, then the non-blocking GPU shards (provider-plan.yml).
        self.assertEqual(list(PLAN_LANES)[:len(BLOCKING_TESTS)], BLOCKING_TESTS)
        self.assertEqual(list(PLAN_LANES)[-3:], ["test-cluster-gpu-1", "test-cluster-gpu-2", "test-cluster-gpu-3"])

    def test_release_and_credentialed_workflows_keep_literal_runners(self):
        for filename in UNROUTED:
            text = self.texts[filename]
            with self.subTest(workflow=filename):
                self.assertNotIn("darkbloom-route.yml", text)
                self.assertNotIn("needs.route", text)
                for runner in re.findall(r"(?m)^\s+runs-on: (.+)$", text):
                    self.assertRegex(runner, r"^(blacksmith-[a-z0-9-]+|ubuntu-24\.04)$")
        for filename, text in self.texts.items():
            # The watchdog names the labels it looks for; it routes nothing.
            if filename not in ("darkbloom-route.yml", WATCHDOG):
                with self.subTest(workflow=filename):
                    for label in ("self-hosted", "darkbloom-linux-arm64", "darkbloom-macos-arm64"):
                        self.assertNotIn(label, text)
        # The plane refuses a Darkbloom-routable job inside a reusable call
        # that passes secrets (darkbloom-sandbox crates/policy/src/first_party/
        # workflow.rs, PASSES_SECRETS), so a workflow that any caller calls
        # with secrets stays unrouted. The release callers pass `secrets: inherit`.
        called_with_secrets = set()
        for filename, text in self.texts.items():
            for name, job in jobs(text).items():
                called = re.fullmatch(r"\./\.github/workflows/(\S+\.yml)", job_field(job, "uses") or "")
                if called and re.search(r"(?m)^    secrets:", job):
                    called_with_secrets.add(called.group(1))
                    with self.subTest(caller=filename, job=name):
                        self.assertIn(called.group(1), UNROUTED)
        self.assertIn("release-provider.yml", called_with_secrets)
        # Unrouted jobs inside routed workflows keep literal runners as well;
        # the release qualification gate runs on ubuntu-24.04.
        for filename, routed in ROUTED.items():
            for name, job in jobs(self.texts[filename]).items():
                if name not in routed and not job_field(job, "uses"):
                    with self.subTest(workflow=filename, job=name):
                        self.assertRegex(job_field(job, "runs-on"), r"^(blacksmith-[a-z0-9-]+|ubuntu-24\.04)$")
                        self.assertNotIn("needs.route", job)

    def test_release_qualification_is_routed_only_through_a_secret_free_call(self):
        # The plane admits a routable job inside a reusable call only when the
        # calling job passes no secrets and has read-only permissions
        # (darkbloom-sandbox crates/policy/src/first_party/workflow.rs,
        # validate_caller). Each release caller has one such call, so each
        # run sends one route request.
        for filename in RELEASE_CALLERS:
            callers = {name: job for name, job in jobs(self.texts[filename]).items()
                       if job_field(job, "uses") == f"./.github/workflows/{RELEASE_QUALIFY}"}
            with self.subTest(caller=filename):
                self.assertEqual(list(callers), ["qualify"])
                job = callers["qualify"]
                self.assertNotRegex(job, r"(?m)^    secrets:")
                self.assertNotRegex(re.sub(r"(?m)^\s*#.*$", "", job), r"(?i)secrets")
                self.assertEqual(permissions(job, 4), {"contents": "read"})
                for name, other in jobs(self.texts[filename]).items():
                    if job_field(other, "uses") == "./.github/workflows/release-provider.yml":
                        self.assertEqual(needs(other), ["qualify"], name)
        # Every caller of a routed reusable workflow passes no secrets and
        # grants only read permissions.
        for filename, text in self.texts.items():
            for name, job in jobs(text).items():
                called = re.fullmatch(r"\./\.github/workflows/(\S+\.yml)", job_field(job, "uses") or "")
                if called and called.group(1) in ROUTED:
                    with self.subTest(caller=filename, job=name):
                        self.assertNotRegex(job, r"(?m)^    secrets:")
                        granted = permissions(job, 4) or permissions(text.split("\njobs:\n", 1)[0], 0)
                        self.assertIsInstance(granted, dict)
                        self.assertTrue(set(granted.values()) <= {"read", "none"}, granted)
        # The qualification workflow reads no secret anywhere, and its route
        # job is its only route request.
        text = self.texts[RELEASE_QUALIFY]
        self.assertNotRegex(re.sub(r"(?m)^\s*#.*$", "", text), r"(?i)(?<![A-Za-z0-9_.])secrets(?![A-Za-z0-9_])")
        self.assertEqual(text.count("uses: ./.github/workflows/darkbloom-route.yml"), 1)
        self.assertEqual(permissions(text.split("\njobs:\n", 1)[0], 0), {"contents": "read"})
        # A routed release job restores no Actions cache: another routed job
        # could have written it. The workflow pins CI_ACTIONS_CACHE off, which
        # skips every cache step of the build action it runs.
        code = re.sub(r"(?m)^\s*#.*\n", "", text)
        self.assertRegex(code.split("\njobs:\n", 1)[0], r"(?m)^  CI_ACTIONS_CACHE: 'off'$")
        self.assertEqual(code.count("CI_ACTIONS_CACHE"), 1)
        self.assertNotIn("actions/cache", code)
        action = (ROOT / ".github/actions/provider-release-build/action.yml").read_text()
        for step in re.split(r"\n    - ", action):
            if re.search(r"(?m)^\s+uses: actions/cache", step):
                self.assertRegex(step, r"(?m)^      if: env\.CI_ACTIONS_CACHE != 'off'")

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
        # signing and credentialed workflows never carry one; a release run
        # carries one only on a qualification shard, before its release call.
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
        # Partially completed or actively running Darkbloom attempts are never
        # cancelled: only runs where zero Darkbloom jobs of the attempt started
        # or succeeded are treated as stranded.
        defs_match = re.search(r"defs='(.*?)'\n", body, re.DOTALL)
        stranded_match = re.search(
            r'stranded=\$\(jq -r --argjson before "\$before" --argjson attempt "\$attempt" "\$defs"\'(.*?)\' <<<"\$jobs"\)',
            body, re.DOTALL)
        self.assertIsNotNone(defs_match)
        self.assertIsNotNone(stranded_match)
        jq_program = defs_match.group(1) + "\n" + stranded_match.group(1)
        before_ts = 1700002000

        def eval_stranded(job_entries):
            proc = subprocess.run(["jq", "-r", "--argjson", "before", str(before_ts), "--argjson", "attempt", "1",
                                   jq_program], input=json.dumps(job_entries), capture_output=True, text=True, check=True)
            return proc.stdout.strip()

        queued_job = {"name": "test-cluster-2", "run_attempt": 1, "status": "queued", "conclusion": None,
                      "runner_id": 0, "runner_name": "", "labels": MACOS, "created_at": "2023-11-14T22:00:00Z"}
        self.assertEqual(eval_stranded([queued_job]), "test-cluster-2")
        # Non-Darkbloom jobs succeeding do not block rescuing stranded Darkbloom jobs.
        blacksmith_done = {"name": "Release Integrity", "run_attempt": 1, "status": "completed",
                           "conclusion": "success", "runner_id": 9, "runner_name": "bs-1",
                           "labels": [LINUX_FALLBACK], "created_at": "2023-11-14T22:00:00Z",
                           "started_at": "2023-11-14T22:00:10Z"}
        self.assertEqual(eval_stranded([blacksmith_done, queued_job]), "test-cluster-2")
        # Any Darkbloom job of the attempt that succeeded or is running prevents cancellation.
        db_succeeded = {"name": "build-cluster", "run_attempt": 1, "status": "completed", "conclusion": "success",
                        "runner_id": 42, "runner_name": "darkbloom-1", "labels": MACOS,
                        "created_at": "2023-11-14T21:50:00Z", "started_at": "2023-11-14T21:51:00Z"}
        db_running = {"name": "test-provider-1", "run_attempt": 1, "status": "in_progress", "conclusion": None,
                      "runner_id": 43, "runner_name": "darkbloom-2", "labels": MACOS,
                      "created_at": "2023-11-14T21:50:00Z", "started_at": "2023-11-14T21:52:00Z"}
        self.assertEqual(eval_stranded([db_succeeded, queued_job]), "")
        self.assertEqual(eval_stranded([db_running, queued_job]), "")

    def test_unlabel_job_scopes_write_permissions_to_hosted_ubuntu_only(self):
        # Only `unlabel` (literal ubuntu-24.04, skipped by Darkbloom routable
        # job checks) holds issues/pull-requests write to consume `run-ci`/`run-gpu-ci`.
        for filename in CALLERS:
            unlabel = jobs(self.texts[filename])["unlabel"]
            self.assertEqual(job_field(unlabel, "runs-on"), "ubuntu-24.04")
            self.assertEqual(
                job_field(unlabel, "if"),
                "${{ github.event_name == 'pull_request' && (github.event.label.name == 'run-ci' || github.event.label.name == 'run-gpu-ci') }}",
            )
            self.assertEqual(permissions(unlabel, 4), {"issues": "write", "pull-requests": "write"})
            for forbidden in ("uses:", "secrets.", "checkout"):
                self.assertNotIn(forbidden, unlabel)
        for filename in (*CALLERS, PLAN, "provider-tests.yml", "darkbloom-route.yml"):
            for name, job in jobs(self.texts[filename]).items():
                if name != "unlabel":
                    self.assertNotIn("issues:", job, f"{filename} {name}")
                    self.assertNotIn("pull-requests:", job, f"{filename} {name}")

    def test_classifier_gate_and_route_need_no_routed_runner(self):
        ci = jobs(self.texts["provider-tests.yml"])
        plan = jobs(self.texts[PLAN])
        # The route reads the plan job's components (the classifier's, after
        # the tree lookup), as the test jobs do.
        self.assertEqual(needs(plan["route"]), ["components"])
        self.assertEqual(job_field(plan["route"], "if"), "${{ !cancelled() }}")
        self.assertEqual(job_field(ci["provider-test-gate"], "runs-on"), "ubuntu-24.04")
        self.assertNotIn("route", needs(ci["provider-test-gate"]))
        # The classifier, the lookup and the choice run in one GitHub-hosted job.
        self.assertEqual(set(plan), {"commit", "components", "route"})
        self.assertEqual(job_field(plan["components"], "runs-on"), "ubuntu-24.04")
        self.assertIn("        run: python3 scripts/ci-component-paths.py\n", plan["components"])
        self.assertIn("python3 scripts/test-darkbloom-route.py", jobs(self.texts["ci-master.yml"])["release-integrity"])
        self.assertEqual(permissions(self.texts["docs-impact.yml"].split("\njobs:\n", 1)[0], 0),
                         {"contents": "read"})


if __name__ == "__main__":
    unittest.main()
