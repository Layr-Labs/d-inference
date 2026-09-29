"""Create and verify the clean build record used by hardware qualification."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess

from .source_provenance import source_identity


def file_digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def encode_build_record(record):
    return (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()


def verified_build_record(record, source, configuration, binaries, metallibs):
    if (not isinstance(record, dict) or not isinstance(source, dict)
            or type(record.get("schema_version")) is not int or record["schema_version"] != 1
            or record.get("clean_build") is not True or record.get("identity_test_passed") is not True
            or record.get("configuration") != configuration or record.get("source") != source
            or source.get("dirty") is not False):
        raise ValueError("clean build record must match the exact measured candidate source")
    for key, current in (("test_binaries_sha256", binaries), ("metallibs_sha256", metallibs)):
        if (not isinstance(current, dict) or not current or not isinstance(record.get(key), dict)
                or set(record[key].values()) != set(current.values())):
            raise ValueError("measured executable or metallib differs from the clean build")
    commands = record.get("commands")
    if (not record.get("toolchain") or not isinstance(commands, list) or len(commands) < 4
            or commands[0] != ["swift", "package", "clean"]
            or commands[1] != ["swift", "build", "-c", configuration, "--build-tests", "-Xswiftc", "-enable-testing"]):
        raise ValueError("clean build must retain its toolchain and commands")
    return record


def load_build_record(path, source, configuration, binaries, metallibs):
    raw = Path(path).read_bytes()
    if len(raw) > 1 << 20:
        raise ValueError("build record exceeds its bounded size")
    record = verified_build_record(json.loads(raw), source, configuration, binaries, metallibs)
    if raw != encode_build_record(record):
        raise ValueError("build record must retain the builder's canonical bytes")
    log = Path(path).with_name("build.log")
    if not log.is_file() or file_digest(log) != record.get("build_log_sha256"):
        raise ValueError("clean build command log is absent or changed")
    return record, hashlib.sha256(raw).hexdigest()


def run_owned(command, cwd, environment, log, timeout):
    process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        except ProcessLookupError:
            pass
        raise
    if status:
        raise RuntimeError(f"qualification build command failed with status {status}: {command[0]}")


def build_candidate(root, output, configuration="release", timeout=1800):
    """Always clean first; existing .build products cannot acquire a new source identity."""
    source = source_identity(root)
    if source.get("dirty") is not False:
        raise ValueError("commit the candidate before building qualification evidence")
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("DARKBLOOM_", "MLX_", "MTPLX_", "QWEN_"))}
    environment["DARKBLOOM_SERVING_QUALIFICATION_BUILD"] = "1"
    package = root / "provider-swift"
    output.mkdir(parents=True, exist_ok=False)
    log_path = output / "build.log"
    commands = [
        ["swift", "package", "clean"],
        ["swift", "build", "-c", configuration, "--build-tests", "-Xswiftc", "-enable-testing"],
    ]
    with log_path.open("w") as log:
        for command in commands:
            run_owned(command, package, environment, log, timeout)
        bin_path = Path(subprocess.check_output(
            ["swift", "build", "-c", configuration, "--show-bin-path"], cwd=package,
            env=environment, text=True, timeout=60).strip())
        stage = [str(root / "scripts/stage-test-metallib.sh"), str(bin_path)]
        commands.append(stage)
        run_owned(stage, root, environment, log, timeout)
        test = ["swift", "test", "--skip-build", "-c", configuration,
                "--filter", "qualificationBuildIdentityMatchesExecutingImage"]
        commands.append(test)
        run_owned(test, package, environment, log, timeout)
    if "qualificationBuildIdentityMatchesExecutingImage() passed" not in log_path.read_text():
        raise ValueError("actual executable identity test did not run and pass")
    if source_identity(root) != source:
        raise ValueError("source changed during clean build")
    binaries = {str(path): file_digest(path) for path in sorted(bin_path.glob("*.xctest/Contents/MacOS/*"))
                if path.is_file() and os.access(path, os.X_OK)}
    metallibs = {str(Path(path).parent / "mlx.metallib"): file_digest(Path(path).parent / "mlx.metallib")
                 for path in binaries}
    record = {"schema_version": 1, "clean_build": True, "identity_test_passed": True,
              "configuration": configuration, "source": source, "commands": commands,
              "toolchain": subprocess.check_output(["swift", "--version"], text=True, timeout=30).strip(),
              "test_binaries_sha256": binaries, "metallibs_sha256": metallibs,
              "build_log_sha256": file_digest(log_path)}
    verified_build_record(record, source, configuration, binaries, metallibs)
    destination = output / "build-receipt.json"
    destination.write_bytes(encode_build_record(record))
    return destination
