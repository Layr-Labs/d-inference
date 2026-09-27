"""Run one owned benchmark at a time, always retaining its raw output."""

import os
import signal
import subprocess
import time

from .provenance import host_snapshot, now, write_json
from .power import power_failure


def stop_owned(process):
    # start_new_session gives this child its own process group. Never kill by
    # executable name: a provider or somebody else's benchmark can coexist.
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def run(command, cwd, environment, directory, timeout, required_ac_power_mode=None):
    before = host_snapshot()
    write_json(directory / "host-before.json", before)
    started = time.monotonic()
    state = {"startedAt": now(), "command": command, "timeoutSeconds": timeout}
    write_json(directory / "process.json", state)
    process = None
    try:
        failure = power_failure(before, required_ac_power_mode)
        if failure:
            state.update({"returncode": 125, "notLaunched": True, "powerRequirementFailed": failure})
            return state
        with (directory / "stdout.raw").open("wb") as stdout, (directory / "stderr.raw").open("wb") as stderr:
            process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=stdout, stderr=stderr,
                                       start_new_session=True)
            try:
                state["returncode"] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                state["timedOut"] = True
                stop_owned(process)
                state["returncode"] = process.returncode
    except BaseException as error:
        if process:
            stop_owned(process)
        state["interrupted"] = type(error).__name__
        raise
    finally:
        state.update({"finishedAt": now(), "wallSeconds": time.monotonic() - started})
        after = host_snapshot()
        failure = power_failure(after, required_ac_power_mode)
        if failure:
            state["powerRequirementFailed"] = failure
        write_json(directory / "process.json", state)
        write_json(directory / "host-after.json", after)
    return state
