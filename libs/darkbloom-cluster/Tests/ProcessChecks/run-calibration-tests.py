#!/usr/bin/env python3
"""Run all canonical calibration process checks without MLX or model packages."""
import argparse
import ast
import contextlib
import ctypes
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
MODULES = ("DarkbloomClusterBootstrap", "DarkbloomClusterProtocol",
           "DarkbloomClusterSecurity", "DarkbloomClusterProcess", "DarkbloomClusterRemote")
MINIMUM_INVOCATIONS = 39
MAX_LOG_BYTES = 4 << 20
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "CalibrationProcessChecks", platforms: [.macOS(.v14)], targets: [
    .target(name: "DarkbloomClusterBootstrap"),
    .target(name: "DarkbloomClusterProtocol"),
    .target(name: "DarkbloomClusterSecurity", dependencies: ["DarkbloomClusterBootstrap"]),
    .target(name: "DarkbloomClusterProcess", dependencies: ["DarkbloomClusterProtocol"]),
    .target(name: "DarkbloomClusterRemote", dependencies: ["DarkbloomClusterProtocol", "DarkbloomClusterProcess", "DarkbloomClusterBootstrap", "DarkbloomClusterSecurity"]),
    .executableTarget(name: "calibration-cpu-fixture", dependencies: ["DarkbloomClusterBootstrap", "DarkbloomClusterProtocol"], path: "Sources/CalibrationFixture"),
    .testTarget(name: "ProcessTests", dependencies: ["DarkbloomClusterProcess", "DarkbloomClusterProtocol", "DarkbloomClusterRemote"]),
])
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected regular source or owned artifact: " + str(path))
    return path


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def source_map():
    """Re-enumerate on every check, so added/deleted sources also invalidate a run."""
    result = {}
    for module in MODULES:
        base = ROOT / "Sources" / module
        paths = sorted(base.rglob("*.swift"))
        if not paths:
            raise ValueError("Empty CPU module: " + module)
        for path in paths:
            regular(path)
            if re.search(r"\bimport\s+(?:MLX\w*|Cmlx|DarkbloomClusterRuntime)\b", path.read_text()):
                raise ValueError("GPU/runtime import in CPU closure: " + str(path))
            result[path] = Path("Sources") / module / path.relative_to(base)
    result[HERE / "CalibrationFixture.swift"] = Path("Sources/CalibrationFixture/CalibrationFixture.swift")
    result[HERE / "ClusterCalibrationProcessTests.swift"] = Path("Tests/ProcessTests/ClusterCalibrationProcessTests.swift")
    # Hash the controller too, even though it is not a Swift package input.
    result[ROOT / "Tests/SecurityChecks/owned_process.py"] = None
    result[Path(__file__).resolve()] = None
    return result


def snapshot(mapping):
    return {str(path): digest(regular(path)) for path in mapping}


def expected_cases(source):
    """Fail closed if this suite adopts unsupported/dynamic test arguments."""
    pattern = r"^\s*@Test(?:\(arguments:\s*(\[[^\]]*\])\))?\s*func\s+(\w+)"
    methods = re.findall(pattern, source, re.M)
    if not methods or len(methods) != len(re.findall(r"^\s*@Test\b", source, re.M)):
        raise ValueError("Update calibration runner for changed Swift Testing attributes")
    result = {}
    for arguments, name in methods:
        values = ast.literal_eval(arguments) if arguments else [None]
        if not isinstance(values, list) or not values or name in result:
            raise ValueError("Invalid or duplicate calibration test declaration")
        if arguments and any(type(value) not in (str, int) for value in values):
            raise ValueError("Update calibration runner for non-scalar Swift test arguments")
        result[name] = len(values)
    return result


def check_test_log(text, expected):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    if re.search(r"^[^A-Za-z0-9]*(?:Test|Suite) .+\b(?:skipped|failed)(?:[.: ]|$)", text, re.M):
        raise ValueError("Calibration tests failed or skipped")
    if re.search(r"(?:with|skipped) [1-9][0-9]* tests? skipped|skipped [1-9][0-9]* test", text):
        raise ValueError("Calibration tests skipped")
    passed = {}
    pattern = r"^[^A-Za-z0-9]*Test (\w+)\([^)]*\)(?: with ([0-9]+) test cases?)? passed after "
    for name, count in re.findall(pattern, text, re.M):
        if name in passed:
            raise ValueError("Duplicate calibration test completion: " + name)
        passed[name] = int(count) if count else 1
    if passed != expected:
        raise ValueError("Incomplete calibration case results: " + json.dumps({"expected": expected, "passed": passed}))
    summaries = re.findall(r"Test run with ([0-9]+) tests?(?: in [1-9][0-9]* suites?)? passed after ", text)
    if len(summaries) != 1 or int(summaries[0]) not in (len(expected), sum(expected.values())):
        raise ValueError("Missing or inconsistent nonzero Swift Testing aggregate")
    return {"passedMethods": len(passed), "passedInvocations": sum(passed.values()), "failed": 0, "skipped": 0}


# Layout from the platform SDK's sys/proc_info.h, PROC_PIDTBSDINFO (flavor3).
# Read the exact birth identity; a persisted bare PID is never signal authority.
class BsdInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tdev", "tpgid")]
    _fields_ += [("nice", ctypes.c_int32), ("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


def process_identity(pid):
    if sys.platform != "darwin" or ctypes.sizeof(BsdInfo) != 136:
        raise ValueError("Calibration fixture ownership requires the macOS libproc layout")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    function = library.proc_pidinfo
    function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    function.restype = ctypes.c_int
    info = BsdInfo()
    count = function(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if count != ctypes.sizeof(info):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return None
        raise ValueError("Cannot establish fixture birth identity for PID " + str(pid))
    if info.pid != pid or not info.seconds:
        raise ValueError("Invalid fixture process identity")
    return {"pid": pid, "uid": info.uid, "seconds": info.seconds, "microseconds": info.microseconds}


def fixture_exec(config_path, arguments):
    """Register then exec: the supervisor observes the same PID, not a proxy child."""
    config = json.loads(regular(config_path).read_text())
    binary = regular(Path(config["binary"]))
    if digest(binary) != config["sha256"]:
        raise ValueError("Fixture binary changed before exec")
    identity = process_identity(os.getpid())
    if identity is None or identity["uid"] != os.getuid():
        raise ValueError("Cannot register owned fixture identity")
    path = Path(config["tracker"]) / (str(os.getpid()) + ".json")
    # Atomic publication: never launch the Swift fixture with an incomplete identity.
    temporary = path.with_suffix(".pending")
    with temporary.open("x") as handle:
        json.dump(identity, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.link(temporary, path)
    temporary.unlink()
    os.execv(str(binary), [str(binary)] + arguments)


def cleanup_fixtures(tracker):
    receipts = []
    for path in sorted(tracker.glob("*.json")):
        row = {"record": path.name, "signalSent": False, "originalAbsent": False}
        receipts.append(row)
        try:
            original = json.loads(regular(path).read_text())
            if set(original) != {"pid", "uid", "seconds", "microseconds"} or any(type(v) is not int for v in original.values()):
                raise ValueError("Invalid private fixture ownership receipt")
            if original["pid"] <= 1 or original["uid"] != os.getuid():
                raise ValueError("Invalid private fixture owner")
            row["identity"] = original
            current = process_identity(original["pid"])
            row["originalAbsent"] = current != original
            if current == original:
                # Only this run's still-matching birth can be signalled. Cleanup
                # never converts a surviving fixture into a successful test gate.
                try:
                    os.kill(original["pid"], signal.SIGKILL)
                    row["signalSent"] = True
                except ProcessLookupError:
                    row["alreadyAbsentBeforeSignal"] = True
                deadline = time.monotonic() + 10
                while process_identity(original["pid"]) == original and time.monotonic() < deadline:
                    time.sleep(.02)
                row["originalAbsent"] = process_identity(original["pid"]) != original
        except BaseException as error:
            row["cleanupError"] = type(error).__name__ + ": " + str(error)
    return receipts


def bounded_timeout(value):
    value = int(value)
    if not 1 <= value <= 600:
        raise argparse.ArgumentTypeError("timeout must be within1...600 seconds")
    return value


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--output", type=Path, help="New retained owner-private directory (default: unique temporary root)")
    parser.add_argument("--compile-timeout", type=bounded_timeout, default=180)
    parser.add_argument("--test-timeout", type=bounded_timeout, default=120)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise ValueError("Calibration CPU runner requires macOS")
    if args.output is None:
        output = Path(tempfile.mkdtemp(prefix="darkbloom-calibration-checks-")).resolve()
    else:
        output = args.output.absolute()
        output.mkdir(mode=0o700, parents=False, exist_ok=False)
        output = output.resolve()
    print("Calibration process receipts: " + str(output), flush=True)
    tracker = output / "fixture-processes"
    tracker.mkdir(mode=0o700)
    final = {"passed": False, "steps": [], "testCommandAttempted": False, "testsExecuted": False, "GPU": False,
             "modelExecuted": False, "externalNetworkUsed": False, "output": str(output)}
    owned = None
    source_before = None
    mapping = None
    try:
        mapping = source_map()
        source_before = snapshot(mapping)
        write_json(output / "source-snapshot.json", source_before)
        expected = expected_cases((HERE / "ClusterCalibrationProcessTests.swift").read_text())
        if sum(expected.values()) < MINIMUM_INVOCATIONS:
            raise ValueError("Report frontier regression prerequisite missing: require at least39 declared invocations")
        write_json(output / "expected-tests.json", expected)
        package = output / "package"
        package.mkdir(mode=0o700)
        for source, destination in mapping.items():
            if destination is not None:
                path = package / destination
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                path.write_bytes(source.read_bytes())
                if digest(path) != source_before[str(source)]:
                    raise ValueError("Source changed while snapshotting: " + str(source))
        (package / "Package.swift").write_text(PACKAGE)
        final["packageSHA256"] = digest(package / "Package.swift")
        write_json(output / "package-snapshot.json", {
            str(path.relative_to(package)): digest(path) for path in sorted(package.rglob("*")) if path.is_file()})
        helper = ROOT / "Tests/SecurityChecks/owned_process.py"
        spec = importlib.util.spec_from_file_location("calibration_owned_process", helper)
        owned = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(owned)

        def unchanged():
            if snapshot(source_map()) != source_before:
                raise ValueError("Canonical CPU source set or bytes changed during run")

        def step(command, name, timeout):
            record = {"argv": command, "timeoutSeconds": timeout}
            started = time.monotonic()
            try:
                with (output / (name + ".stdout")).open("xb") as stdout, (output / (name + ".stderr")).open("xb") as stderr:
                    with contextlib.redirect_stdout(io.StringIO()) as observation:
                        owned.invoke_controller(command, stdout, stderr, record, timeout=timeout)
                    record["launchObservation"] = observation.getvalue()
            except BaseException as error:
                record["timedOut"] = isinstance(error, subprocess.TimeoutExpired)
                raise
            finally:
                record["elapsedSeconds"] = time.monotonic() - started
                write_json(output / (name + ".json"), record)
                final["steps"].append(record)
            for suffix in ("stdout", "stderr"):
                if (output / (name + "." + suffix)).stat().st_size > MAX_LOG_BYTES:
                    raise ValueError("Diagnostic bound exceeded: " + name)
            if record.get("exitCode") != 0 or not record.get("reaped") or not record.get("groupAbsent"):
                raise ValueError("Owned command failed: " + name)
            unchanged()
            return (output / (name + ".stdout")).read_text() + (output / (name + ".stderr")).read_text()

        unchanged()
        step(["xcrun", "swift", "--version"], "toolchain", 30)
        common = ["--package-path", str(package), "--scratch-path", str(output / "build"), "--jobs", "2"]
        step(["xcrun", "swift", "build"] + common + ["--product", "calibration-cpu-fixture", "-Xswiftc", "-warnings-as-errors"], "fixture-build", args.compile_timeout)
        step(["xcrun", "swift", "build"] + common + ["--build-tests", "-Xswiftc", "-warnings-as-errors"], "tests-build", args.compile_timeout)
        step(["xcrun", "swift", "build"] + common + ["--show-bin-path"], "binary-location", 30)
        location = (output / "binary-location.stdout").read_text().strip()
        if len(location.splitlines()) != 1 or not location.startswith("/"):
            raise ValueError("Invalid Swift bin path output")
        directory = Path(location).resolve()
        if not directory.is_relative_to(output):
            raise ValueError("Swift bin path escaped owned output")
        binary = regular(directory / "calibration-cpu-fixture")
        binaries = {str(path.relative_to(output)): digest(path) for path in sorted(directory.rglob("*"))
                    if path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o111}
        if not binaries or not any(".xctest" in path for path in binaries):
            raise ValueError("Actual Swift test executable not found in owned bin path")
        write_json(output / "binaries.json", binaries)
        config = output / "fixture-exec.json"
        write_json(config, {"binary": str(binary), "sha256": digest(binary), "tracker": str(tracker)})
        # Copy this reviewed runner for fixture exec, avoiding a moving source path.
        frozen_driver = output / "fixture-driver.py"
        frozen_driver.write_bytes(Path(__file__).read_bytes())
        wrapper = output / "calibration-fixture"
        wrapper.write_text("#!" + sys.executable + "\nimport os, sys\nos.execv(" + repr(sys.executable) + ", [" + repr(sys.executable)
                           + ", '-B', " + repr(str(frozen_driver)) + ", '--fixture-exec', " + repr(str(config)) + "] + sys.argv[1:])\n")
        wrapper.chmod(0o700)
        final["fixtureExecWrapperSHA256"] = digest(wrapper)
        final["fixtureDriverSHA256"] = digest(frozen_driver)
        artifacts = {str(path.relative_to(output)): digest(path) for path in (wrapper, frozen_driver, config, package / "Package.swift")}
        final["harnessArtifacts"] = artifacts
        final["testCommandAttempted"] = True
        log = step(["/usr/bin/env", "CALIBRATION_CPU_FIXTURE=" + str(wrapper), "xcrun", "swift", "test"]
                   + common + ["--skip-build", "--no-parallel", "--filter", "ClusterCalibrationProcessTests"], "tests", args.test_timeout)
        final["testsExecuted"] = True
        final["counts"] = check_test_log(log, expected)
        final["binariesUnchanged"] = all(digest(output / path) == value for path, value in {**binaries, **artifacts}.items())
        if not final["binariesUnchanged"]:
            raise ValueError("CPU binaries changed during execution")
        unchanged()
        final["passed"] = True
    except BaseException as error:
        final["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        test_logs = [output / ("tests." + suffix) for suffix in ("stdout", "stderr")]
        # Preserve actual observations even when a nonzero controller prevented
        # the complete-pass oracle from running. No failed-case count is guessed.
        excerpts = []
        for path in test_logs:
            if path.exists():
                with path.open("rb") as handle:
                    excerpts.append(handle.read(MAX_LOG_BYTES).decode("utf-8", errors="replace"))
        text = "\n".join(excerpts)
        text = re.sub(r"\x1b\[[0-9;]*m", "", text)
        final["testsExecuted"] = bool(re.search(r"Test run started|Test \w+\([^)]*\) started", text))
        final["testOutputObservations"] = {
            "aggregateLines": [line for line in text.splitlines() if "Test run with " in line],
            "failureOrSkipLines": [line for line in text.splitlines()
                if re.search(r"(?:Test|Suite) .*\b(?:failed|skipped)(?:[.: ]|$)", line)][:256],
        }
        try:
            cleanup = cleanup_fixtures(tracker)
            final["fixtureCleanup"] = cleanup
            final["allFixtureBirthsAbsent"] = all(item["originalAbsent"] for item in cleanup)
            if not final["allFixtureBirthsAbsent"] or any(item["signalSent"] for item in cleanup) or (final["passed"] and not cleanup):
                final["passed"] = False
                final["cleanupFailure"] = "Fixture survived controller; emergency cleanup cannot turn gate green"
        except BaseException as error:
            final["passed"] = False
            final["cleanupFailure"] = type(error).__name__ + ": " + str(error)
        if source_before is not None:
            try:
                final["sourceUnchanged"] = snapshot(source_map()) == source_before
            except BaseException as error:
                final["sourceUnchanged"] = False
                final["sourceRecheckError"] = type(error).__name__ + ": " + str(error)
            if not final["sourceUnchanged"]:
                final["passed"] = False
        write_json(output / "checks.json", final)
    if not final["passed"]:
        raise ValueError("Calibration gate failed; inspect retained checks.json")
    print("PASS calibration process: " + str(final["counts"]["passedInvocations"]) + " invocations; zero skips; " + str(output))


def interrupted(signum, _frame):
    raise InterruptedError("Runner interrupted by signal " + str(signum))


if __name__ == "__main__":
    os.umask(0o077)
    if len(sys.argv) >= 3 and sys.argv[1] == "--fixture-exec":
        fixture_exec(Path(sys.argv[2]), sys.argv[3:])
    else:
        for runner_signal in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(runner_signal, interrupted)
        main()
