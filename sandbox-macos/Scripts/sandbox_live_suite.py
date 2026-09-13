"""Real consumer operations; no coordinator admin or host mutation shortcuts."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import time
import uuid

from sandbox_live_evidence import denied, digest, identity, require, success, utc
from sandbox_live_quota import workspace_exhaustion

TERMINAL = {"succeeded", "failed", "timed_out", "cancelled", "lost"}


class LiveSuite:
    def __init__(self, client):
        self.client = client
        self.created = []
        self.pending = {}
        self.results = []
        self.sandboxes = []
        self.fixture = bytes(range(256)) * 4097 + b"\x00exact-tail\xff\r\n"
        self.input = client.root / "fixture.bin"
        self.input.write_bytes(self.fixture)
        self.transfers = []
        self.not_covered = [] if client.config.get("workspace_exhaustion", False) else ["workspace_exhaustion"]

    def save_ownership(self):
        self.client.write("ownership.json", {"created_ids": self.created, "pending_creations": self.pending,
            "cleanup_scope": "only IDs returned by this run's saved create idempotency keys"})

    def create(self, label):
        key = str(uuid.uuid4())
        config = self.client.config
        args = ["create", "--wait=false", "--image", config["base_image_id"], "--cpu", str(config.get("cpu", 4)),
                "--memory-gib", str(config.get("memory_gib", 8)), "--workspace-gib", str(config.get("workspace_gib", 25))]
        self.pending[key] = {"arguments": args, "label": label}
        self.save_ownership()  # Durable before any possibly successful mutation.
        return self.resolve_creation(key)

    def resolve_creation(self, key):
        pending = self.pending[key]
        last = None
        for _ in range(3):
            last = self.client.call(pending["label"], pending["arguments"], key=key)
            record, payload = last
            if isinstance(payload, dict) and isinstance(payload.get("sandbox"), dict):
                sandbox = payload["sandbox"]
                sandbox_id = identity(sandbox.get("id"))
                require(sandbox.get("base_image_id") == self.client.config["base_image_id"], "create returned wrong image")
                require(sandbox_id not in self.created, "independent create keys returned the same sandbox")
                self.created.append(sandbox_id)
                del self.pending[key]
                self.save_ownership()
                success(last)
                return sandbox_id
            # A definite API rejection did not create an object. A transport or
            # server failure remains in the ledger for same-key reconciliation.
            if isinstance(payload, dict) and re.search(r"\(HTTP 4\d\d\)$", payload.get("error", "")):
                del self.pending[key]
                self.save_ownership()
                break
        success(last)
        raise AssertionError("creation identity unavailable; saved idempotency key requires reconciliation")

    def inspect(self, sandbox_id, label="inspect"):
        value = success(self.client.call(label, ["inspect", sandbox_id]))
        require(value.get("id") == sandbox_id, "inspect identity changed")
        return value

    def wait_state(self, sandbox_id, desired, seconds=None, interval=2):
        deadline = time.monotonic() + (seconds or self.client.config.get("readiness_seconds", 600))
        while True:
            value = self.inspect(sandbox_id, "wait-" + desired)
            if value.get("state") == desired:
                return value
            require(value.get("state") != "failed", "sandbox entered failed state; reservation may be retained")
            require(time.monotonic() < deadline, "sandbox did not reach " + desired)
            time.sleep(interval)

    def lifecycle(self, action, sandbox_id, target):
        require(sandbox_id in self.created, "lifecycle mutation outside owned sandbox set")
        success(self.client.call(action, [action, "--wait=false", sandbox_id], key=str(uuid.uuid4())))
        return self.wait_state(sandbox_id, target)

    def submit(self, sandbox_id, arguments, timeout=30, label="submit"):
        command = success(self.client.call(label, ["exec", "--wait=false", "--timeout", str(timeout), sandbox_id,
                                                    "--"] + arguments, key=str(uuid.uuid4())))
        identity(command.get("id"))
        require(command.get("sandbox_id") == sandbox_id, "command sandbox identity mismatch")
        return command

    def status(self, sandbox_id, command_id):
        command = success(self.client.call("job-status", ["job", "status", sandbox_id, command_id]))
        require(command.get("id") == command_id and command.get("sandbox_id") == sandbox_id,
                "command identity mismatch")
        return command

    def wait_job(self, sandbox_id, command_id, seconds=120):
        deadline = time.monotonic() + seconds
        while True:
            command = self.status(sandbox_id, command_id)
            if command.get("state") in TERMINAL and command.get("cancellation_pending") is False:
                require(not command.get("payload_expired", False), "test output expired before validation")
                return command
            require(time.monotonic() < deadline, "command completion or cleanup remained uncertain")
            time.sleep(1)

    def execute(self, sandbox_id, arguments, timeout=30, expected="succeeded", label="exec"):
        submitted = self.submit(sandbox_id, arguments, timeout, label)
        command = self.wait_job(sandbox_id, submitted["id"], max(120, timeout + 60))
        require(command.get("state") == expected, "unexpected terminal command state: " + str(command.get("state")))
        if expected == "succeeded":
            require(command.get("exit_code") == 0, "successful command has nonzero exit")
        return command

    def recovered(self, sandbox_id, expect_vm_stop=False):
        # Cancellation acknowledgement can precede the stopped heartbeat. Do
        # not race that authoritative transition by dispatching into stale ready.
        value = self.wait_state(sandbox_id, "stopped", seconds=60) if expect_vm_stop else self.inspect(sandbox_id)
        if value["state"] == "stopping":
            value = self.wait_state(sandbox_id, "stopped")
        if value["state"] == "stopped":
            self.lifecycle("start", sandbox_id, "ready")
        else:
            require(value["state"] == "ready", "command cleanup did not leave a recoverable sandbox")
        output = self.execute(sandbox_id, ["/usr/bin/printf", "recovered\n"])
        require(output.get("stdout") == "recovered\n", "recovery positive control failed")

    def create_two(self):
        record, _ = self.client.call("cli-help", ["help"])
        require(record["exit_code"] == 0 and not record["capture_truncated"], "CLI help unavailable")
        help_text = (self.client.root / record["stdout"]["path"]).read_text()
        require(all(command in help_text for command in ["start|stop|delete|renew", "upload-status", "download"]),
                "CLI lacks required lifecycle/file commands")
        for label in ["create-a", "create-b"]:
            sandbox_id = self.create(label)
            self.sandboxes.append(sandbox_id)
            self.wait_state(sandbox_id, "ready")
        require(len(set(self.sandboxes)) == 2, "two distinct sandboxes are required")

    def exact_files_and_isolation(self):
        for index, sandbox_id in enumerate(self.sandboxes):
            transfer = str(uuid.uuid4())
            path = f"instance-{index}.bin"
            record = success(self.client.call("upload", ["upload", "--transfer-id", transfer,
                                           sandbox_id, str(self.input), path], timeout=180))
            require(record.get("state") == "committed" and record.get("sha256") == digest(self.fixture)
                    and record.get("size") == len(self.fixture), "upload did not commit exact fixture")
            self.transfers.append(transfer)
            self.download_exact(sandbox_id, path, f"download-{index}.bin")
        first, second = self.sandboxes
        denied(self.client.call("foreign-transfer", ["upload-status", second, self.transfers[0]]), "transfer_not_found")
        foreign = self.client.root / "foreign.bin"
        denied(self.client.call("foreign-file", ["download", second, "instance-0.bin", str(foreign)]), "file_not_found")
        require(not foreign.exists(), "failed cross-instance download published a local file")
        # Recheck both positive controls after denial, so an unavailable host
        # cannot accidentally count as evidence of isolation.
        for index, sandbox_id in enumerate(self.sandboxes):
            self.download_exact(sandbox_id, f"instance-{index}.bin", f"positive-after-denial-{index}.bin")

    def download_exact(self, sandbox_id, remote, local):
        target = self.client.root / local
        result = success(self.client.call("download", ["download", sandbox_id, remote, str(target)], timeout=180))
        require(result.get("size") == len(self.fixture) and target.read_bytes() == self.fixture, "download bytes differ")
        self.client.write(local + ".digest.json", {"path": local, "bytes": len(self.fixture), "sha256": digest(target.read_bytes())})

    def tenant_identity(self):
        script = """set -eu
/usr/bin/id -u
/usr/bin/id -g
/usr/bin/id -G
test ! -r /var/db/darkbloom-sandbox/instance.json
test -x /usr/bin/sudo && test -x /usr/bin/crontab && test -x /usr/bin/atq && test -x /usr/bin/at
if /usr/bin/sudo -n /usr/bin/true >/dev/null 2>&1; then exit 91; fi
if /usr/bin/crontab -l >/dev/null 2>&1; then exit 92; fi
if /usr/bin/atq >/dev/null 2>&1; then exit 93; fi
if printf '* * * * * /usr/bin/true\\n' | /usr/bin/env USER=root LOGNAME=root /usr/bin/crontab - >/dev/null 2>&1; then exit 94; fi
if printf '/usr/bin/true\\n' | /usr/bin/env USER=root LOGNAME=root /usr/bin/at now + 1 minute >/dev/null 2>&1; then exit 95; fi
printf 'policy-denied\n'
"""
        for sandbox_id in self.sandboxes:
            value = self.execute(sandbox_id, ["/bin/sh", "-c", script], label="tenant-identity")
            lines = value.get("stdout", "").splitlines()
            require(len(lines) == 4 and lines[0] == "2001" and lines[1] == "2001"
                    and set(lines[2].split()) == {"2001"} and lines[3] == "policy-denied", "tenant identity or privileges differ")

    def network_denial(self):
        for sandbox_id in self.sandboxes:
            value = self.execute(sandbox_id, ["/sbin/ifconfig", "-a"], label="network-interfaces")
            interface = None
            for line in value.get("stdout", "").splitlines():
                match = re.match(r"^([A-Za-z0-9]+):", line)
                if match:
                    interface = match[1]
                if re.match(r"\s+inet6?\s", line):
                    require(interface == "lo0", "guest has an IP interface beyond loopback")
            require("lo0:" in value.get("stdout", ""), "interface inspection positive control missing")
            script = "test -x /usr/bin/nc || exit 89; if /usr/bin/nc -G 2 -w 2 -z 198.51.100.1 443; then exit 90; fi; printf 'network-denied\\n'"
            result = self.execute(sandbox_id, ["/bin/sh", "-c", script], label="network-connect-denial")
            require(result.get("stdout") == "network-denied\n", "network-denial probe failed")

    def bounded_output(self):
        stdout = "/usr/bin/head -c 2097152 /dev/zero | /usr/bin/tr '\\000' O"
        stderr = "/usr/bin/head -c 2097152 /dev/zero | /usr/bin/tr '\\000' E >&2"
        for script, field, character in [(stdout, "stdout", "O"), (stderr, "stderr", "E")]:
            value = self.execute(self.sandboxes[0], ["/bin/sh", "-c", script], label="bounded-" + field)
            require(value.get("output_truncated") is True and value.get(field) == character * 1048576,
                    "individual stream was not bounded to one MiB")
        script = stdout + "; " + stderr
        value = self.execute(self.sandboxes[0], ["/bin/sh", "-c", script], label="bounded-output")
        require(value.get("output_truncated") is True, "truncation not reported")
        for field, character in [("stdout", "O"), ("stderr", "E")]:
            text = value.get(field, "")
            require(131072 <= len(text) <= 1048576 and text == character * len(text),
                    "combined output lost a stream or exceeded its bound")

    def timeout_cancel_recovery(self):
        sandbox_id = self.sandboxes[0]
        # Delayed child would modify a sentinel after timeout if cleanup leaked it.
        script = "(/bin/sleep 12; /usr/bin/touch /workspace/escaped-timeout) & /bin/sleep 60"
        self.execute(sandbox_id, ["/bin/sh", "-c", script], timeout=2, expected="timed_out", label="timeout-tree")
        self.recovered(sandbox_id)
        command = self.submit(sandbox_id, ["/bin/sh", "-c",
            "(/bin/sleep 12; /usr/bin/touch /workspace/escaped-cancel) & /bin/sleep 60"], timeout=90, label="cancel-tree")
        deadline = time.monotonic() + 60
        while self.status(sandbox_id, command["id"])["state"] != "running":
            require(time.monotonic() < deadline, "cancellation command never ran")
            time.sleep(1)
        success(self.client.call("job-cancel", ["job", "cancel", sandbox_id, command["id"]]))
        result = self.wait_job(sandbox_id, command["id"])
        require(result["state"] == "cancelled", "cancellation did not complete")
        self.recovered(sandbox_id, expect_vm_stop=True)
        self.execute(sandbox_id, ["/bin/sh", "-c", "/bin/sleep 14; test ! -e escaped-timeout && test ! -e escaped-cancel"],
                     timeout=30, label="descendant-positive-control")

    def persistence(self):
        sandbox_id = self.sandboxes[0]
        self.lifecycle("stop", sandbox_id, "stopped")
        self.lifecycle("start", sandbox_id, "ready")
        self.download_exact(sandbox_id, "instance-0.bin", "persisted-after-restart.bin")

    def concurrent_jobs(self):
        def submit(index):
            return self.submit(self.sandboxes[index], ["/bin/sh", "-c", f"/bin/sleep 12; printf 'parallel-{index}\\n'"],
                               timeout=45, label="parallel-" + str(index))
        with ThreadPoolExecutor(max_workers=2) as pool:
            commands = [future.result() for future in [pool.submit(submit, index) for index in range(2)]]
        deadline = time.monotonic() + 60
        while True:
            statuses = [self.status(sandbox_id, command["id"]) for sandbox_id, command in zip(self.sandboxes, commands)]
            if all(status["state"] == "running" for status in statuses):
                break
            require(not any(status["state"] in TERMINAL for status in statuses) and time.monotonic() < deadline,
                    "two jobs never overlapped in running state")
            time.sleep(0.5)
        for index, command in enumerate(commands):
            value = self.wait_job(self.sandboxes[index], command["id"])
            require(value.get("state") == "succeeded" and value.get("stdout") == f"parallel-{index}\n",
                    "concurrent job output mismatch")

    def delete_and_expiry(self):
        self.lifecycle("delete", self.sandboxes[0], "deleted")
        sandbox_id = self.sandboxes[1]
        value = self.lifecycle("stop", sandbox_id, "stopped")
        expiry = datetime.fromisoformat(value["lease_expires_at"].replace("Z", "+00:00"))
        remaining = max(0, (expiry - datetime.now(timezone.utc)).total_seconds())
        budget = self.client.config.get("expiry_seconds", 2100)
        require(remaining + 60 <= budget, "expiry budget too short; natural lease expiry was not tested")
        print("Waiting for the created sandbox's real lease expiry; no lease renewal or clock mutation.", flush=True)
        self.wait_state(sandbox_id, "deleted", budget, interval=15)
        require(datetime.now(timezone.utc) >= expiry, "sandbox was deleted before natural lease expiry")

    def cleanup(self):
        failures = []
        for key in list(self.pending):
            try:
                self.resolve_creation(key)
            except Exception:
                failures.append("creation outcome unresolved for saved key " + key)
        for sandbox_id in list(self.created):
            try:
                if self.inspect(sandbox_id, "cleanup-inspect")["state"] != "deleted":
                    self.lifecycle("delete", sandbox_id, "deleted")
            except Exception:
                failures.append("deletion unconfirmed for " + sandbox_id)
        self.client.write("cleanup.json", {"finished_at": utc(), "failures": failures,
            "created_ids": self.created, "pending_creation_keys": list(self.pending),
            "proof": "consumer API terminal states; physical host inventory is a separate gate"})
        return failures

    def run(self):
        cases = [("create_two", self.create_two), ("exact_files_and_isolation", self.exact_files_and_isolation),
                 ("tenant_identity", self.tenant_identity), ("network_denial", self.network_denial),
                 ("bounded_output", self.bounded_output), ("timeout_cancel_recovery", self.timeout_cancel_recovery),
                 ("workspace_persistence", self.persistence), ("concurrent_jobs", self.concurrent_jobs),
                 ("delete_and_expiry", self.delete_and_expiry)]
        if self.client.config.get("workspace_exhaustion", False):
            cases.insert(-1, ("workspace_exhaustion", lambda: workspace_exhaustion(self)))
        failed = False
        try:
            for name, action in cases:
                if failed:
                    self.results.append({"case": name, "status": "blocked", "reason": "earlier acceptance case failed"})
                    continue
                start = time.monotonic()
                before = len(self.client.records)
                print("Testing " + name, flush=True)
                try:
                    action()
                    result = {"case": name, "status": "passed"}
                except Exception as error:
                    failed = True
                    result = {"case": name, "status": "failed", "reason": str(error)}
                result.update(duration_seconds=time.monotonic() - start,
                              evidence=[r["stdout"]["path"][:-7] + ".json" for r in self.client.records[before:]])
                self.results.append(result)
                self.client.write("results.json", self.results)
        finally:
            failures = self.cleanup()
            self.client.write("summary.json", {"passed": not failed and not failures and len(self.results) == len(cases),
                "cases": self.results, "cleanup_failures": failures, "not_covered": self.not_covered,
                "finished_at": utc()})
        return not failed and not failures
