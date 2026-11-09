#!/usr/bin/env python3
"""Drive the guided cluster setup through the real desktop API, end to end and isolated.

The API runs this build's own `darkbloom cluster --app-console` (the real onboarding, with its live
operations) in a home of its own. Its coordinator is a local fixture that never approves the account
for clusters, so every run ends at the clusters waitlist gate, which comes before the onboarding's
operations exist: no cable, pairing, service or network setting of this Mac is read or changed.
If the setup's screen ever opened (a `banner` or `heading` event), the run is cancelled at once and
the test fails.

Checks: a session starts and streams its events; the gate's question arrives as a `choose`;
an answer (No, Yes) or a cancel reaches the child and ends the run as the terminal's would; the
SSE stream carries every change; one session at a time; a running session refuses other actions.
With `--record FILE`, the declined run's sessions, as the event stream delivered them, are written
for the app's tests (desktop-app/tests/fixtures/cluster-session-waitlist-gate.json).
"""
import argparse
import http.client
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request


class Coordinator(http.server.BaseHTTPRequestHandler):
    """The coordinator's waitlist routes only: `cluster` is never approved (none, then waitlisted)."""

    def send_json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def place(self):
        joined = self.server.cluster_joined
        place = {"feature": "cluster", "title": "Clusters", "summary": "Serve one model with two to four of your Macs.",
                 "start_command": "darkbloom cluster", "status": "waitlisted" if joined else "none"}
        if joined:
            place.update(position=7, requested_at="2026-11-09T00:00:00Z")
        return place

    def route(self, method):
        if not self.path.startswith("/v1/waitlists"):
            return self.send_json(404, {"error": {"message": "not in this fixture"}})
        if not self.headers.get("Authorization"):
            return self.send_json(401, {"error": {"message": "login required"}})
        feature = self.path[len("/v1/waitlists/"):] if self.path.startswith("/v1/waitlists/") else None
        if feature is None:
            return self.send_json(200, {"data": [self.place()]})
        if feature != "cluster":
            return self.send_json(404, {"error": {"message": "no such waitlist"}})
        if method == "POST":
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.server.cluster_joined = True
            self.server.posts.append(self.path)
        else:
            self.server.reads.append(self.path)
        return self.send_json(200, self.place())

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def log_message(self, *_):
        pass


class API:
    def __init__(self, binary, root, coordinator):
        home = root / "home"
        (home / ".config/darkbloom").mkdir(parents=True)
        self.config = home / ".config/darkbloom/provider.toml"
        self.config.write_text(f'[provider]\nname = "Isolated fixture"\nauto_update = false\n'
                               f'[coordinator]\nurl = "http://127.0.0.1:{coordinator.server_port}"\n')
        token = root / "auth"
        token.write_text("fixture-provider-token")
        token.chmod(0o600)
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), DARKBLOOM_DESKTOP_DIR=str(root / "desktop"),
                   DARKBLOOM_AUTH_TOKEN_PATH=str(token), DARKBLOOM_STATE_FILE=str(root / "state.json"),
                   DARKBLOOM_LOCAL_DIR=str(root / "local"), DARKBLOOM_SANDBOX_ROOT=str(root / "sandbox-addon"),
                   DARKBLOOM_NO_UPDATE_CHECK="1")
        self.log = (root / "api.log").open("w")
        self.process = subprocess.Popen([str(binary), "desktop", "serve", "--config", str(self.config)], env=env,
                                        stdout=self.log, stderr=self.log)
        discovery = root / "desktop/connection.json"
        for _ in range(150):
            if discovery.exists() or self.process.poll() is not None:
                break
            time.sleep(.1)
        assert discovery.exists(), (root / "api.log").read_text()
        connection = json.loads(discovery.read_text())
        self.base = f'http://127.0.0.1:{connection["port"]}/control/v1/'
        self.token = connection["token"]

    def request(self, path, body=None):
        request = urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None,
                                         headers={"Content-Type": "application/json",
                                                  "Authorization": "Bearer " + self.token})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def stream(self, sink, stop):
        """Every `cluster-session` frame of the event stream, in order, until `stop` is set."""
        port = int(self.base.split(":")[2].split("/")[0])
        while not stop.is_set():
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=70)
            try:
                connection.request("GET", "/control/v1/cluster/session/events",
                                   headers={"Authorization": "Bearer " + self.token})
                response = connection.getresponse()
                event, data = None, []
                while not stop.is_set():
                    raw = response.fp.readline()
                    if not raw:
                        break
                    line = raw.decode().rstrip("\n").rstrip("\r")
                    if line.startswith("event:"):
                        event = line[6:].strip()
                    elif line.startswith("data:"):
                        data.append(line[6:] if line.startswith("data: ") else line[5:])
                    elif line == "":
                        if event == "cluster-session" and data:
                            sink.append(json.loads("\n".join(data)))
                        event, data = None, []
            except OSError:
                time.sleep(.2)
            finally:
                connection.close()

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.log.close()


def said(session):
    return [event.get("text", "") for event in session["events"] if event.get("type") == "say"]


def screen_opened(session):
    return any(event.get("type") in ("banner", "heading") for event in session["events"])


def wait_for(api, predicate, what, seconds=60):
    deadline = time.time() + seconds
    while time.time() < deadline:
        code, session = api.request("cluster/session")
        assert code == 200, session
        if session and screen_opened(session):
            api.request("cluster/session/answer", {"cancel": True})
            raise AssertionError("the setup's screen opened: the waitlist gate didn't stop it\n" + json.dumps(session))
        if session and predicate(session):
            return session
        time.sleep(.1)
    raise AssertionError(f"timed out waiting for {what}: {json.dumps(session)}")


def gate_question(api):
    session = wait_for(api, lambda s: s["question"] is not None or s["state"] != "running", "the gate's question")
    question = session["question"]
    assert session["state"] == "running" and question and question["type"] == "choose", session
    titles = [rows[0] for rows in question["options"]]
    assert titles == ["Yes", "No"] and question["selected"] == 1, question
    assert any("Join the Clusters waitlist now?" in line for line in said(session)), said(session)
    return session, question


def streamed(frames, session_id, question, seconds=5):
    """Waits, as a person does, until the event stream has shown the question: the stream samples the session every
    200 ms, so a state that lasts less than that (an answer sent at once) may never be streamed."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if any(frame and frame["id"] == session_id and frame["question"] == question for frame in list(frames)):
            return
        time.sleep(.05)
    raise AssertionError("the event stream never showed the question")


def ended(api):
    return wait_for(api, lambda s: s["state"] != "running", "the run's end")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--record", type=Path, help="write the declined run's streamed sessions here")
    args = parser.parse_args()
    coordinator = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Coordinator)
    coordinator.cluster_joined, coordinator.reads, coordinator.posts = False, [], []
    threading.Thread(target=coordinator.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="dcs-") as directory:
        api = API(args.binary.resolve(), Path(directory), coordinator)
        frames, stop = [], threading.Event()
        threading.Thread(target=api.stream, args=(frames, stop), daemon=True).start()
        try:
            code, capabilities = api.request("state")
            assert code == 200 and "cluster_session" in capabilities["capabilities"], capabilities
            assert api.request("cluster/session") == (200, None)

            # Declined: the gate asks, No ends the run as the terminal's would, and nothing is joined.
            code, session = api.request("cluster/session", {"kind": "setup"})
            assert code == 202 and session["kind"] == "setup" and session["state"] == "running", session
            first = session["id"]
            _, question = gate_question(api)
            streamed(frames, first, question)
            # One setup at a time, and while it runs it holds the API's mutation slot.
            code, refused = api.request("cluster/session", {"kind": "setup"})
            assert code == 409 and refused["error"] == "A cluster setup is already running.", refused
            # A `settings` action (never `stop` or `start`: launchd labels are this user's, not the isolated home's),
            # which could only ever write the isolated provider.toml had the session not refused it.
            code, refused = api.request("actions", {"id": "6c5f1f62-8a1e-4c8f-9a4e-2f0f3b2d0c11", "action": "settings",
                                                    "revision": "stale", "name": "Isolated fixture",
                                                    "idle_minutes": 60, "auto_update": False})
            assert code in (400, 409) and refused["error"] == "A cluster setup is already running.", refused
            code, answered = api.request("cluster/session/answer", {"question": question["id"], "choice": 1})
            assert code == 200 and answered["question"] is None, answered
            code, stale = api.request("cluster/session/answer", {"question": question["id"], "choice": 1})
            assert code == 409, stale
            session = ended(api)
            assert session["id"] == first and session["state"] == "failed" and session["exit_code"] == 1, session
            lines = said(session)
            assert any("darkbloom waitlist cluster" in line for line in lines), lines
            assert any("darkbloom cluster local" in line for line in lines), lines
            assert coordinator.reads.count("/v1/waitlists/cluster") >= 1 and not coordinator.posts, coordinator.reads
            time.sleep(.5)
            declined = [frame for frame in frames if frame and frame["id"] == first]
            assert declined and declined[-1] == session, (declined[-1:], session)
            assert any(frame["question"] for frame in declined), "the stream never carried the question"
            if args.record:
                args.record.write_text(json.dumps(declined, indent=2, ensure_ascii=False) + "\n")

            # Joined: Yes puts the account on the waitlist, which still stops the run before anything is set up.
            code, session = api.request("cluster/session", {"kind": "setup"})
            assert code == 202 and session["id"] != first, session
            _, question = gate_question(api)
            api.request("cluster/session/answer", {"question": question["id"], "choice": 0})
            session = ended(api)
            assert session["state"] == "failed" and session["exit_code"] == 1, session
            assert coordinator.posts == ["/v1/waitlists/cluster"], coordinator.posts
            assert any("#7 in line" in line for line in said(session)), said(session)

            # Cancelled: a cancel answers the pending question as the terminal's q does.
            coordinator.cluster_joined = False
            code, session = api.request("cluster/session", {"kind": "setup"})
            assert code == 202, session
            gate_question(api)
            api.request("cluster/session/answer", {"cancel": True})
            session = ended(api)
            assert session["state"] in ("cancelled", "failed"), session
            assert coordinator.posts == ["/v1/waitlists/cluster"], coordinator.posts
            print(f"desktop-cluster-session: {len(frames)} streamed sessions; the real `cluster --app-console` asked "
                  "its waitlist question, took No, Yes and a cancel, held the mutation slot, and stopped at the gate "
                  "each time with nothing set up")
        finally:
            stop.set()
            api.close()
            coordinator.shutdown()


if __name__ == "__main__":
    main()
