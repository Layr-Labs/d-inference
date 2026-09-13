"""Opt-in exhaustion of one created guest's fixed workspace device only."""

import uuid

from sandbox_live_evidence import digest, require, success


def workspace_exhaustion(suite):
    sandbox_id = suite.sandboxes[0]
    require(sandbox_id in suite.created, "quota probe requires a sandbox created by this run")
    name = "quota-" + str(uuid.uuid4()) + ".bin"
    path = "/workspace/" + name
    # This guest-only destination is never translated to a host path. Asking
    # for capacity + 1 GiB proves the fixed device refuses growth past its cap.
    count_mib = (suite.client.config.get("workspace_gib", 25) + 1) * 1024
    try:
        value = suite.execute(sandbox_id, ["/bin/dd", "if=/dev/zero", "of=" + path,
            "bs=1048576", "count=" + str(count_mib)], timeout=900, expected="failed", label="workspace-exhaustion")
        require(value.get("exit_code", 0) != 0 and "No space left on device" in value.get("stderr", ""),
                "workspace exhaustion did not report ENOSPC (a timeout or another I/O error is not quota proof)")
        # Exercise the root supervisor/control channel while the tenant volume
        # is still full. This command itself needs no workspace allocation.
        control = suite.execute(sandbox_id, ["/usr/bin/id", "-u"], label="control-while-workspace-full")
        require(control.get("stdout") == "2001\n", "control channel unavailable while workspace is full")
    finally:
        # The unique path is the only guest file removed by the quota case.
        suite.recovered(sandbox_id)
        suite.execute(sandbox_id, ["/bin/rm", "-f", "--", path], label="quota-file-cleanup")
    target = "quota-recovery-" + str(uuid.uuid4()) + ".bin"
    transfer = success(suite.client.call("quota-recovery-upload", ["upload", sandbox_id,
                                       str(suite.input), target], timeout=180))
    require(transfer.get("state") == "committed" and transfer.get("sha256") == digest(suite.fixture),
            "workspace did not accept a verified upload after ENOSPC cleanup")
    suite.download_exact(sandbox_id, target, "quota-recovery-download.bin")
