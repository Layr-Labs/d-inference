"""Partial-transfer restart, abort and revision-bound download acceptance."""

import uuid

from sandbox_live_evidence import denied, digest, require, success
from sandbox_live_http import CHUNK_BYTES, FileAPI, download_chunk, file_denied, json_success


def partial_upload(suite, api, sandbox_id, label):
    transfer_id = str(uuid.uuid4())
    path = label + "-" + transfer_id + ".bin"
    metadata = {"transfer_id": transfer_id, "path": path, "size": len(suite.fixture),
                "sha256": digest(suite.fixture)}
    suite.client.write(label + "-intent.json", {"sandbox_id": sandbox_id, **metadata,
        "interruption_boundary": "after one acknowledged chunk; resume uses a new CLI process"})
    begun = json_success(api.call(label + "-begin", sandbox_id, "begin", body=metadata))
    check_transfer(begun, transfer_id, suite.fixture, "uploading", 0)
    chunk = suite.fixture[:CHUNK_BYTES]
    sent = json_success(api.call(label + "-chunk", sandbox_id, "chunk", transfer_id=transfer_id,
                                 query={"offset": 0}, body=chunk))
    check_transfer(sent, transfer_id, suite.fixture, "uploading", len(chunk))
    return transfer_id, path


def check_transfer(value, transfer_id, content, state, offset):
    require(value.get("transfer_id") == transfer_id and value.get("size") == len(content)
            and value.get("sha256") == digest(content) and value.get("state") == state
            and value.get("offset") == offset, "transfer commitment or acknowledged offset differs")


def transfer_recovery(suite):
    sandbox_id = suite.sandboxes[0]
    api = FileAPI(suite)
    transfer_id, path = partial_upload(suite, api, sandbox_id, "resume")
    status = success(suite.client.call("resume-status", ["upload-status", sandbox_id, transfer_id]))
    check_transfer(status, transfer_id, suite.fixture, "uploading", CHUNK_BYTES)
    resumed = success(suite.client.call("resume-fresh-cli", ["upload", "--transfer-id", transfer_id,
                       sandbox_id, str(suite.input), path], timeout=180))
    check_transfer(resumed, transfer_id, suite.fixture, "committed", len(suite.fixture))
    suite.download_exact(sandbox_id, path, "resumed-exact.bin")
    denied(suite.client.call("committed-abort-denial", ["upload-abort", sandbox_id, transfer_id]),
           "upload_already_committed", status=409)
    suite.download_exact(sandbox_id, path, "committed-after-abort-denial.bin")

    aborted_id, aborted_path = partial_upload(suite, api, sandbox_id, "abort")
    require_missing_file(suite, sandbox_id, aborted_path, "partial-not-published")
    aborted = success(suite.client.call("abort-partial", ["upload-abort", sandbox_id, aborted_id]))
    require(aborted.get("transfer_id") == aborted_id and aborted.get("state") == "aborted",
            "partial upload abort not confirmed")
    status = success(suite.client.call("abort-status", ["upload-status", sandbox_id, aborted_id]))
    require(status.get("transfer_id") == aborted_id and status.get("state") == "aborted",
            "aborted transfer state not retained")
    require_missing_file(suite, sandbox_id, aborted_path, "aborted-not-published")
    suite.download_exact(sandbox_id, path, "abort-positive-control.bin")
    revision_change(suite, api, sandbox_id, path)


def require_missing_file(suite, sandbox_id, path, label):
    local = suite.client.root / (label + ".bin")
    denied(suite.client.call(label, ["download", sandbox_id, path, str(local)]), "file_not_found")
    require(not local.exists(), "unpublished upload produced a local download")


def revision_change(suite, api, sandbox_id, path):
    first = api.call("revision-first", sandbox_id, "download", query={"path": path, "length": CHUNK_BYTES})
    version = download_chunk(first, suite.fixture[:CHUNK_BYTES], 0, len(suite.fixture))
    # This is a tenant file modification under the existing exec contract, not
    # a raw guest operation or a privileged file-transfer shortcut.
    suite.execute(sandbox_id, ["/bin/sh", "-c", "printf x >> /workspace/" + path], label="revision-append")
    stale = api.call("revision-stale", sandbox_id, "download", query={"path": path, "offset": CHUNK_BYTES,
        "length": CHUNK_BYTES, "version": version})
    file_denied(stale, "file_changed")
    changed = suite.fixture + b"x"
    fresh = api.call("revision-fresh", sandbox_id, "download", query={"path": path, "length": CHUNK_BYTES})
    replacement = download_chunk(fresh, changed[:CHUNK_BYTES], 0, len(changed))
    require(replacement != version, "file mutation did not change revision identity")
    suite.download_exact(sandbox_id, path, "revision-positive-control.bin", expected=changed)
