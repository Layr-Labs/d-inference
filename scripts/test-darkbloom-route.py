#!/usr/bin/env python3
"""Exercise the Darkbloom route step against a loopback HTTPS plane; pin callers.

The route step runs exactly as the workflow defines it, with throwaway TLS
credentials and the real curl/jq. It must choose only between each lane's
fallback label and the exact Darkbloom label array for its profile, and must
never fail because of the plane. The workflow checks pin every routed job,
its fallback, timeout and read-only permissions, and keep release paths on
literal runners. Requires Bash, Python, jq, curl and openssl.
"""

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
PROVIDER = "${{ needs.changes.outputs.provider == 'true' && 1 || 0 }}"
PULL_REQUEST_WARM = "${{ github.event_name == 'pull_request' && 2 || 0 }}"
# Every routed job: (profile, fallback label, count expression or None for 1).
ROUTED = {
    "ci.yml": {
        "release-integrity": ("linux_arm64", LINUX_FALLBACK, None),
        "docs": ("linux_arm64", LINUX_FALLBACK, None),
        "test-provider": ("macos_arm64", MACOS_FALLBACK, PROVIDER),
        "test-provider-sdk": ("macos_arm64", MACOS_FALLBACK, PROVIDER),
        "test-provider-parity": ("macos_arm64", MACOS_FALLBACK, PROVIDER),
        "test-cluster-checks": ("macos_arm64", MACOS_FALLBACK, PROVIDER),
    },
    "docs-impact.yml": {
        "commit-signatures": ("linux_arm64", LINUX_FALLBACK, None),
        "docs-impact": ("linux_arm64", LINUX_FALLBACK, None),
    },
    "landing.yml": {"check": ("linux_arm64", LINUX_FALLBACK, None)},
    "desktop.yml": {"frontend": ("linux_arm64", LINUX_FALLBACK, None)},
    "nightly-linear-package.yml": {"test": ("linux_arm64", LINUX_FALLBACK, None)},
    "provider-release-cache.yml": {"warm": ("macos_arm64", MACOS_FALLBACK, PULL_REQUEST_WARM)},
}
# Credentialed, release, review or publication workflows keep literal runners.
UNROUTED = ("release-swift.yml", "release-provider.yml", "release-dev-branch.yml",
            "release-desktop.yml", "provider-signing-validation.yml", "register-model.yml",
            "threat-model-review.yml", "bedrock-smoke.yml", "claude.yml", "codex.yml")
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


def lane_lines(route_job):
    """Return the caller's literal `lanes` block lines, before expression evaluation."""
    return literal_block(route_job, "lanes", 6).splitlines()


def route_lanes(route_job):
    """Parse the caller's `lanes` lines into {lane: (profile, fallback, count)}."""
    lanes = {}
    for line in lane_lines(route_job):
        lane, profile, fallback, *count = line.split(maxsplit=3)
        lanes[lane] = (profile, fallback, count[0] if count else None)
    return lanes


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
                   f"docs linux_arm64 {LINUX_FALLBACK}\ndocs macos_arm64 {MACOS_FALLBACK}")
        with self.plane() as plane:
            for lanes in invalid:
                with self.subTest(lanes=lanes):
                    result, routes, _ = self.route(plane.url, lanes=lanes)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("::error title=Darkbloom route configuration::", result.stdout)
                    self.assertIsNone(routes)
        self.assertEqual(plane.requests, [])

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


class RouteWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.texts = {path.name: path.read_text() for path in WORKFLOWS.glob("*.yml")}

    def test_every_workflow_is_classified(self):
        self.assertEqual(set(self.texts), set(ROUTED) | set(UNROUTED) |
                         {"darkbloom-route.yml", "component-changes.yml"})

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
                                 "PLANE_URL": "vars.DARKBLOOM_SANDBOX_URL", "REPOSITORY": "github.repository",
                                 "EVENT_NAME": "github.event_name",
                                 "HEAD_REPOSITORY": "github.event.pull_request.head.repo.full_name",
                                 "RUN_ID": "github.run_id", "RUN_ATTEMPT": "github.run_attempt"}.items():
            self.assertIn(f"          {name}: ${{{{ {expression} }}}}\n", select)
        script = route_step()
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
                self.assertEqual(route_lanes(route), expected)
            for name, (_, _, count) in expected.items():
                job = workflow[name]
                with self.subTest(workflow=filename, job=name):
                    self.assertIn("route", needs(job))
                    self.assertEqual(job_field(job, "runs-on"), RUNS_ON.get(
                        name, f"${{{{ fromJSON(needs.route.outputs.routes)['{name}'] }}}}"))
                    condition = job_field(job, "if")
                    if name != "warm":
                        # A lane is requested exactly when its job runs.
                        self.assertEqual(count, None if condition is None
                                         else condition.replace(" }}", " && 1 || 0 }}"))
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
            text = "\n".join(lane_lines(jobs(self.texts[filename])["route"])) + "\n"
            for outcome in ("1", "0"):
                # Evaluate each `${{ condition && N || 0 }}` count both ways.
                lanes = re.sub(r"\$\{\{ .+? && (\d+) \|\| 0 \}\}",
                               lambda match: match.group(1) if outcome == "1" else "0", text)
                with self.subTest(workflow=filename, requested=outcome), tempfile.TemporaryDirectory() as work:
                    result, routes, _ = run_route_step(
                        script, Path(work), LANES=lanes, ROUTING="", PLANE_URL="", EVENT_NAME="push",
                        HEAD_REPOSITORY="", REPOSITORY="Layr-Labs/d-inference", RUN_ID="1", RUN_ATTEMPT="1")
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(routes, [{name: fallback for name, (_, fallback, _)
                                               in ROUTED[filename].items()}])

    def test_release_and_credentialed_workflows_keep_literal_runners(self):
        for filename in UNROUTED:
            text = self.texts[filename]
            with self.subTest(workflow=filename):
                self.assertNotIn("darkbloom-route.yml", text)
                self.assertNotIn("needs.route", text)
                for runner in re.findall(r"(?m)^\s+runs-on: (.+)$", text):
                    self.assertRegex(runner, r"^blacksmith-[a-z0-9-]+$")
        for filename, text in self.texts.items():
            if filename != "darkbloom-route.yml":
                with self.subTest(workflow=filename):
                    for label in ("self-hosted", "darkbloom-linux-arm64", "darkbloom-macos-arm64"):
                        self.assertNotIn(label, text)
        # Unrouted jobs inside routed workflows keep literal runners as well.
        for filename, routed in ROUTED.items():
            for name, job in jobs(self.texts[filename]).items():
                if name not in routed and not job_field(job, "uses"):
                    with self.subTest(workflow=filename, job=name):
                        self.assertRegex(job_field(job, "runs-on"), r"^(blacksmith-[a-z0-9-]+|ubuntu-24\.04)$")
        ci = jobs(self.texts["ci.yml"])
        self.assertEqual(job_field(ci["cache-swift"], "runs-on"), MACOS_FALLBACK)

    def test_classifier_gate_and_route_need_no_routed_runner(self):
        ci = jobs(self.texts["ci.yml"])
        self.assertEqual(needs(ci["route"]), ["changes"])
        self.assertEqual(job_field(ci["route"], "if"), "${{ !cancelled() }}")
        self.assertEqual(job_field(ci["provider-test-gate"], "runs-on"), "ubuntu-24.04")
        self.assertNotIn("route", needs(ci["provider-test-gate"]))
        changes = jobs(self.texts["component-changes.yml"])["changes"]
        self.assertEqual(job_field(changes, "runs-on"), "ubuntu-24.04")
        self.assertIn("python3 scripts/test-darkbloom-route.py", ci["release-integrity"])
        self.assertEqual(permissions(self.texts["docs-impact.yml"].split("\njobs:\n", 1)[0], 0),
                         {"contents": "read"})


if __name__ == "__main__":
    unittest.main()
