"""Natural lease expiry with observed work; never stop, renew or alter clocks."""

from datetime import datetime, timezone
import time

from sandbox_live_evidence import require, utc


def seconds_until(expiry):
    return (expiry - datetime.now(timezone.utc)).total_seconds()


def delete_and_expiry(suite):
    suite.lifecycle("delete", suite.sandboxes[0], "deleted")
    sandbox_id = suite.sandboxes[1]
    require(sandbox_id in suite.created, "expiry requires a sandbox created by this run")
    value = suite.inspect(sandbox_id, "expiry-ready")
    require(value.get("state") == "ready", "natural expiry requires a running ready VM")
    expiry_text = value["lease_expires_at"]
    expiry = datetime.fromisoformat(expiry_text.replace("Z", "+00:00"))
    budget = suite.client.config.get("expiry_seconds", 2100)
    require(seconds_until(expiry) + 60 <= budget, "expiry budget too short; natural expiry not tested")
    deadline = time.monotonic() + budget
    evidence = {"sandbox_id": sandbox_id, "lease_expires_at": expiry_text,
        "no_stop_renew_or_clock_mutation": True,
        "limit": "Command deadlines must fit the lease; command timeout and lease expiry can race. "
                 "API terminal states require separate physical inventory proof."}
    suite.client.write("natural-expiry.json", evidence)
    print("Waiting for the created ready sandbox's real lease expiry; no stop, renewal or clock mutation.", flush=True)
    while seconds_until(expiry) > 60:
        require(time.monotonic() < deadline, "natural expiry budget exhausted")
        time.sleep(min(15, max(0.1, seconds_until(expiry) - 60)))
        current = suite.inspect(sandbox_id, "expiry-wait-ready")
        require(current.get("state") == "ready" and current.get("lease_expires_at") == expiry_text,
                "sandbox stopped or immutable expiry changed before active-work probe")
    remaining = seconds_until(expiry)
    require(remaining >= 20, "insufficient lease remaining for meaningful running-command expiry proof")
    timeout = int(remaining) - 2  # Fit the public API's deadline rule, including dispatch overhead.
    command = suite.submit(sandbox_id, ["/bin/sleep", "120"], timeout=timeout, label="expiry-running-command")
    evidence.update(command_id=command["id"], command_timeout_seconds=timeout)
    suite.client.write("natural-expiry.json", evidence)
    observed = False
    while seconds_until(expiry) > 0:
        require(time.monotonic() < deadline, "natural expiry budget exhausted")
        current = suite.status(sandbox_id, command["id"])
        if current.get("state") == "running":
            evidence["last_running_observation_at"] = utc()
            evidence["last_running_seconds_before_expiry"] = seconds_until(expiry)
            suite.client.write("natural-expiry.json", evidence)
            if seconds_until(expiry) <= 12:
                observed = True
                break
        elif current.get("state") in {"succeeded", "failed", "timed_out", "cancelled", "lost"}:
            break
        time.sleep(2)
    require(observed, "no running command was observed in the final twelve seconds of the lease")
    suite.wait_state(sandbox_id, "deleted", max(1, deadline - time.monotonic()), interval=2)
    require(seconds_until(expiry) <= 0, "sandbox deleted before natural lease expiry")
    final = suite.wait_job(sandbox_id, command["id"], max(1, deadline - time.monotonic()))
    require(final.get("state") in {"timed_out", "cancelled", "lost", "failed"}
            and final.get("cancellation_pending") is False, "expiry command retained active or uncertain work")
    evidence.update(naturally_deleted_at=utc(), command_terminal_state=final["state"],
                    command_cancellation_pending=False, selected_api_observations_passed=True)
    suite.client.write("natural-expiry.json", evidence)
