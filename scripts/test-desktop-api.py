#!/usr/bin/env python3
"""Exercise the real CLI HTTP API using temporary state and a local catalog.

No provider is started. Settings and a cancelled local login use temporary state.
"""
import argparse
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid


class Catalog(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/v1/device/code", self.path
        self.server.link_started.set()
        self.server.link_release.wait(10)
        try:
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"fixture login cancelled")
        except (BrokenPipeError, ConnectionResetError):
            # Cancelling the login drops the CLI's connection before this
            # fixture replies, so a disconnected client here is expected.
            pass

    def do_GET(self):
        if self.path in ("/v1/stats", "/v1/leaderboard?metric=earnings&window=24h"):
            assert self.headers.get("Authorization") is None
            payload = {"total_tokens": 9007199254740993, "active_providers": 7,
                       "provider_regions": [{"region": "Tokyo", "country": "Japan",
                                             "latitude": 35, "longitude": 139, "providers": 7}]} if self.path == "/v1/stats" else {
                "metric": "earnings", "window": "24h", "entries": [{"rank": 1, "pseudonym": "fixture-provider", "tokens": 9007199254740993,
                             "earnings_micro_usd": 12345678}]}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())
            return
        if self.path.startswith("/v1/provider/desktop/insights?window="):
            assert self.headers.get("Authorization") == "Bearer fixture-provider-token"
            if self.server.hold_insights:
                self.server.insights_started.set()
                self.server.insights_release.wait(10)
            window = self.path.split("window=")[1]
            assert window in ("7d", "30d")
            body = json.dumps({"window": window, "lifetime": {"completion_tokens": "9007199254740993"}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"models":[]}')

    def log_message(self, *_):
        pass


def copy_binary(source, destination):
    # A clone is instant on APFS; fall back to a byte copy elsewhere.
    if subprocess.run(["/bin/cp", "-c", str(source), str(destination)], capture_output=True).returncode != 0:
        shutil.copy2(source, destination)


def check_replacement_exit(binary, root, config, env):
    """A serve process exits once its executable is replaced, so launchd relaunches the new one."""
    copy = root / "replaceable" / "darkbloom"
    copy.parent.mkdir()
    copy_binary(binary, copy)
    env = dict(env, DARKBLOOM_DESKTOP_DIR=str(root / "replaceable-desktop"))
    with (root / "replaceable.log").open("w") as log:
        process = subprocess.Popen([str(copy), "desktop", "serve", "--config", str(config),
                                    "--replacement-check-seconds", "1"], env=env, stdout=log, stderr=log)
        try:
            discovery = root / "replaceable-desktop/connection.json"
            for _ in range(100):
                if discovery.exists() or process.poll() is not None:
                    break
                time.sleep(.1)
            assert discovery.exists(), (root / "replaceable.log").read_text()
            time.sleep(2.5)
            assert process.poll() is None, "API exited although its executable was unchanged"
            replacement = copy.with_name(".darkbloom.new")
            copy_binary(binary, replacement)
            os.replace(replacement, copy)
            assert process.wait(timeout=10) == 0, (root / "replaceable.log").read_text()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--hold", action="store_true", help="Keep the isolated API available for a manual Electron bridge check")
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Catalog)
    server.link_started = threading.Event()
    server.link_release = threading.Event()
    server.hold_insights = False
    server.insights_started = threading.Event()
    server.insights_release = threading.Event()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="darkbloom-desktop-test-") as temporary:
        root = Path(temporary)
        cache = root / "models"
        cache.mkdir()
        config = root / "provider.toml"
        config.write_text(f'''[provider]
name = "Desktop fixture"
auto_update = false
[coordinator]
url = "http://127.0.0.1:{server.server_port}"
[backend]
model_cache_directory = "{cache}"
idle_timeout_mins = 60
''')
        env = dict(os.environ, DARKBLOOM_DESKTOP_DIR=str(root / "desktop"),
                   DARKBLOOM_AUTH_TOKEN_PATH=str(root / "auth"),
                   DARKBLOOM_STATE_FILE=str(root / "state.json"),
                   DARKBLOOM_LOCAL_DIR=str(root / "local"),
                   DARKBLOOM_NO_UPDATE_CHECK="1")
        with (root / "log").open("w") as log:
            process = subprocess.Popen([str(args.binary.resolve()), "desktop", "serve", "--config", str(config)], env=env, stdout=log, stderr=log)
            try:
                discovery = root / "desktop/connection.json"
                for _ in range(100):
                    if discovery.exists():
                        break
                    if process.poll() is not None:
                        raise AssertionError((root / "log").read_text())
                    time.sleep(.1)
                connection = json.loads(discovery.read_text())
                assert discovery.stat().st_mode & 0o077 == 0

                def request(path="state", body=None, auth=True, origin=None):
                    headers = {"Content-Type": "application/json"}
                    if auth:
                        headers["Authorization"] = "Bearer " + connection["token"]
                    if origin:
                        headers["Origin"] = origin
                    req = urllib.request.Request(f'http://127.0.0.1:{connection["port"]}/control/v1/{path}',
                                                 data=json.dumps(body).encode() if body else None, headers=headers)
                    try:
                        with urllib.request.urlopen(req, timeout=15) as response:
                            return response.status, json.load(response)
                    except urllib.error.HTTPError as error:
                        return error.code, json.load(error)

                assert request(auth=False)[0] == 401
                assert request(origin="https://untrusted.example")[0] == 401
                code, snapshot = request()
                assert code == 200 and snapshot["machine"]["name"] == "Desktop fixture", snapshot
                assert snapshot["state"] == "stopped" and not snapshot["linked"]
                code, network = request("network")
                assert code == 200 and network["total_tokens"] == "9007199254740993", network
                assert network["provider_regions"][0]["region"] == "Tokyo", network
                code, leaders = request("leaderboard")
                assert code == 200 and leaders["entries"][0]["earnings_micro_usd"] == "12345678", leaders
                assert leaders["metric"] == "earnings" and leaders["window"] == "24h", leaders
                assert leaders["entries"][0]["tokens"] == "9007199254740993", leaders
                initial_account = snapshot["account_revision"]
                assert request("insights-week")[0] == 401
                (root / "auth").write_text("fixture-provider-token")
                (root / "auth").chmod(0o600)
                linked_snapshot = request()[1]
                assert linked_snapshot["account_revision"] != initial_account
                assert "fixture-provider-token" not in json.dumps(linked_snapshot)
                for resource, window in (("insights-week", "7d"), ("insights-month", "30d")):
                    code, insights = request(resource)
                    assert code == 200 and insights["window"] == window, insights
                    assert insights["lifetime"]["completion_tokens"] == "9007199254740993"
                server.hold_insights = True
                inflight_result = []
                inflight = threading.Thread(target=lambda: inflight_result.append(request("insights-week")))
                inflight.start()
                assert server.insights_started.wait(5), "insights request did not reach fixture"
                (root / "auth").unlink()
                server.insights_release.set()
                inflight.join(10)
                assert inflight_result and inflight_result[0][0] == 401, inflight_result
                server.hold_insights = False
                assert request()[1]["account_revision"] != linked_snapshot["account_revision"]
                assert request("insights-week")[0] == 401
                code, rejected = request("actions", {"id": str(uuid.uuid4()), "action": "start", "models": ["--force"]})
                assert code == 400 and rejected["error"] == "Invalid model ID", rejected
                code, malformed = request("actions", {"action": "start"})
                assert code == 400 and malformed["error"] == "Invalid request body", malformed
                code, oversized = request("actions", {"id": str(uuid.uuid4()), "action": "settings", "name": "x" * 17000})
                assert code == 413, (code, oversized)
                code, unknown = request("not-a-resource")
                assert code == 404 and unknown["error"] == "Unknown resource", unknown
                streams = []
                try:
                    for _ in range(8):
                        stream = http.client.HTTPConnection("127.0.0.1", connection["port"], timeout=15)
                        stream.request("GET", "/control/v1/events", headers={"Authorization": "Bearer " + connection["token"]})
                        assert stream.getresponse().status == 200
                        streams.append(stream)
                    code, limited = request("events")
                    assert code == 429, (code, limited)
                finally:
                    for stream in streams:
                        stream.close()
                action = {"id": str(uuid.uuid4()), "action": "settings", "revision": snapshot["settings"]["revision"],
                          "name": "Updated fixture", "idle_minutes": 15, "auto_update": False}
                code, operation = request("actions", action)
                assert code == 202, operation
                for _ in range(40):
                    snapshot = request()[1]
                    if snapshot["operations"][0]["state"] != "running":
                        break
                    time.sleep(.1)
                assert snapshot["operations"][0]["state"] == "succeeded", snapshot
                assert snapshot["settings"]["name"] == "Updated fixture"
                before = hashlib.sha256(config.read_bytes()).hexdigest()
                assert request("actions", action)[1]["id"] == operation["id"]
                assert hashlib.sha256(config.read_bytes()).hexdigest() == before
                conflict = dict(action, name="Unexpected overwrite")
                assert request("actions", conflict)[0] == 400
                link_id = str(uuid.uuid4())
                assert request("actions", {"id": link_id, "action": "link"})[0] == 202
                assert server.link_started.wait(10), "Native login did not reach the local server"
                code, cancelling = request("actions", {"id": str(uuid.uuid4()), "action": "cancel", "operation": link_id})
                assert code == 202 and cancelling["state"] == "running", cancelling
                assert not cancelling["cancellable"], cancelling
                server.link_release.set()
                for _ in range(40):
                    snapshot = request()[1]
                    if snapshot["operations"][0]["state"] != "running":
                        break
                    time.sleep(.1)
                assert snapshot["operations"][0]["state"] == "cancelled", snapshot
                assert not snapshot["linked"] and snapshot["link"] is None, snapshot
                check_replacement_exit(args.binary.resolve(), root, config, env)
                print("desktop-api: authentication, isolation, account insights, exact counters, state, settings, idempotency, cancellation, validation, error statuses, and replaced-executable exit passed")
                if args.hold:
                    print("DARKBLOOM_DESKTOP_DIR=" + str(root / "desktop"), flush=True)
                    input("Press Enter to stop the isolated API: ")
            finally:
                server.link_release.set()
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    server.shutdown()


if __name__ == "__main__":
    main()
