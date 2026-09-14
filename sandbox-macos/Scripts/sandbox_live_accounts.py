"""Cross-account denials with separate owner ledgers and real positive controls."""

import time
import uuid

from sandbox_live_evidence import denied, require, success, utc


def wait_running(suite, sandbox_id, command_id):
    deadline = time.monotonic() + 60
    while True:
        state = suite.status(sandbox_id, command_id).get("state")
        if state == "running":
            return
        require(state in {"pending", "accepted"} and time.monotonic() < deadline,
                "account positive-control command never reached running")
        time.sleep(1)


def upload_control(suite, sandbox_id, path):
    result = success(suite.client.call("account-upload", ["upload", "--transfer-id", str(uuid.uuid4()),
                     sandbox_id, str(suite.input), path], timeout=180))
    require(result.get("state") == "committed", "account positive-control upload failed")
    suite.download_exact(sandbox_id, path, "account-download-before.bin")


def account_isolation(primary):
    require(primary.secondary_client is not None and len(primary.sandboxes) == 1,
            "account isolation requires a second credential and exactly one primary VM")
    require(primary.secondary_client.root.parent == primary.client.root,
            "second-account evidence must remain in this campaign directory")
    secondary = type(primary)(primary.secondary_client)
    primary.related_evidence["second_account_authorization"] = [
        "second-account/account-isolation.json", "second-account/ownership.json", "second-account/cleanup.json"]
    secondary.save_ownership()
    first = primary.sandboxes[0]
    require(first in primary.created, "foreign-account probes must target this run's primary resource")
    record = {"primary_sandbox_id": first, "started_at": utc(), "selected_cases_passed": False,
              "scope": "only resources created by this campaign; independent account keys and cleanup ledgers",
              "maximum_simultaneous_vms": 2}
    secondary.client.write("account-isolation.json", record)
    passed = False
    try:
        own = secondary.create("secondary-create")
        secondary.sandboxes.append(own)
        require(own != first and own not in primary.created, "separate account create reused a primary resource")
        secondary.wait_state(own, "ready")
        record["secondary_sandbox_id"] = own
        secondary.client.write("account-isolation.json", record)
        require(secondary.inspect(own).get("state") == "ready", "secondary owner inspect failed")
        output = secondary.execute(own, ["/usr/bin/printf", "secondary-owner\n"], label="secondary-exec")
        require(output.get("stdout") == "secondary-owner\n", "secondary owner exec failed")
        own_path, first_path = "secondary-" + own + ".bin", "primary-" + first + ".bin"
        upload_control(secondary, own, own_path)
        upload_control(primary, first, first_path)
        # Prove cancellation works for this second key on its own real command.
        cancellable = secondary.submit(own, ["/bin/sleep", "60"], timeout=90, label="secondary-cancellable")
        wait_running(secondary, own, cancellable["id"])
        success(secondary.client.call("secondary-own-cancel", ["job", "cancel", own, cancellable["id"]]))
        cancelled = secondary.wait_job(own, cancellable["id"])
        require(cancelled.get("state") == "cancelled", "secondary owner cancellation did not finish")
        secondary.recovered(own, expect_vm_stop=True)
        secondary.download_exact(own, own_path, "account-download-after-cancel.bin")

        active = primary.submit(first, ["/bin/sleep", "30"], timeout=60, label="primary-cancel-target")
        wait_running(primary, first, active["id"])
        foreign_output = secondary.client.root / "foreign-account.bin"
        forbidden_marker = "/workspace/foreign-account-exec-" + str(uuid.uuid4())
        probes = [("inspect", ["inspect", first]),
                  ("exec", ["exec", "--wait=false", "--timeout", "30", first, "--", "/usr/bin/touch", forbidden_marker]),
                  ("read_files", ["download", first, first_path, str(foreign_output)]),
                  ("cancel", ["job", "cancel", first, active["id"]]),
                  ("delete", ["delete", "--wait=false", first])]
        for name, arguments in probes:
            denied(secondary.client.call("foreign-account-" + name, arguments,
                   key=str(uuid.uuid4()) if name in {"exec", "delete"} else None), "sandbox_not_found")
        require(not foreign_output.exists(), "cross-account read published a local file")
        completed = primary.wait_job(first, active["id"])
        require(completed.get("state") == "succeeded" and completed.get("exit_code") == 0,
                "foreign cancellation or deletion affected the primary command")
        output = primary.execute(first, ["/bin/sh", "-c", "test ! -e " + forbidden_marker +
                                 " && printf 'primary-owner\\n'"], label="primary-after-denials")
        require(output.get("stdout") == "primary-owner\n", "primary owner lost usable execution")
        primary.download_exact(first, first_path, "account-download-after-denials.bin")
        secondary.lifecycle("delete", own, "deleted")
        record["denied_operations"] = [name for name, _ in probes]
        passed = True
    finally:
        failures = secondary.cleanup()  # Uses only the second account's own returned IDs/keys.
        record.update(finished_at=utc(), selected_cases_passed=passed and not failures,
                      cleanup_failures=failures, evidence=[r["evidence_file"] for r in secondary.client.records])
        secondary.client.write("account-isolation.json", record)
        require(not failures, "second-account cleanup unconfirmed; see its separate ownership ledger")
    primary.not_covered.remove("second_account_authorization")
