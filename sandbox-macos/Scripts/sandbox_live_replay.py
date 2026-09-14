"""Consumer idempotency commitments verified with an observable command effect."""

import uuid

from sandbox_live_evidence import denied, require


def command_replay(suite):
    sandbox_id = suite.sandboxes[0]
    require(sandbox_id in suite.created, "replay requires a sandbox created by this run")
    key = str(uuid.uuid4())
    path = "/workspace/replay-" + key
    args = ["/bin/sh", "-c", "printf 'once\\n' >> " + path + "; printf 'original\\n'"]
    suite.client.write("command-replay-intent.json", {"sandbox_id": sandbox_id, "key": key, "arguments": args})
    first = suite.submit(sandbox_id, args, key=key, label="replay-original")
    original = suite.wait_job(sandbox_id, first["id"])
    require(original.get("state") == "succeeded" and original.get("stdout") == "original\n",
            "original replay command failed")
    repeated = suite.submit(sandbox_id, args, key=key, label="replay-same-key")
    require(repeated.get("id") == original["id"], "same-key command replay allocated a new command")
    replayed = suite.wait_job(sandbox_id, repeated["id"])
    require(replayed == original, "same-key replay changed the saved command result")
    conflict = suite.client.call("replay-conflict", ["exec", "--wait=false", "--timeout", "30", sandbox_id,
        "--", "/usr/bin/printf", "conflicting\n"], key=key)
    denied(conflict, "sandbox_state_conflict", status=409)
    after = suite.execute(sandbox_id, ["/bin/cat", path], label="replay-effect-positive-control")
    require(after.get("stdout") == "once\n", "replayed command executed its side effect more than once")
