#!/usr/bin/env python3
"""Run explicit sandbox validation stages and retain a machine-readable record."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

from sandbox_release_support import PACKAGE, new_directory, run, sha256, write_json


def source_digest() -> str:
    digest = hashlib.sha256()
    paths = [PACKAGE / "Package.swift"]
    for name in ["Sources", "Tests", "Scripts", "Resources", "ThirdParty", "Benchmarks"]:
        paths.extend(p for p in (PACKAGE / name).rglob("*")
                     if p.is_file() and "__pycache__" not in p.parts)
    coordination = PACKAGE.parent / "host-runtime"
    paths.append(coordination / "Package.swift")
    for name in ["Sources", "Tests"]:
        paths.extend(p for p in (coordination / name).rglob("*") if p.is_file())
    paths.extend(p for p in (PACKAGE.parent / "coordinator/cmd/darkbloom-sandbox").rglob("*") if p.is_file())
    for path in sorted(paths):
        digest.update(path.relative_to(PACKAGE.parent).as_posix().encode() + b"\0")
        digest.update(sha256(path).encode() + b"\n")
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--coordinator", action="store_true")
    parser.add_argument("--consumer-config", type=Path,
                        help="run real consumer acceptance against explicit nonproduction JSON configuration")
    parser.add_argument("--workspace-exhaustion", action="store_true",
                        help="include physical guest workspace exhaustion in consumer acceptance")
    parser.add_argument("--second-account", action="store_true",
                        help="include two-consumer ownership proof using private DARKBLOOM_SECONDARY_API_KEY")
    parser.add_argument("--lume", type=Path, help="run pinned real-binary contracts")
    parser.add_argument("--live-restore", action="store_true")
    parser.add_argument("--prepare-base", action="store_true")
    parser.add_argument("--two-vms", action="store_true")
    parser.add_argument("--storage", type=Path)
    parser.add_argument("--ipsw", type=Path)
    parser.add_argument("--base-name", default="darkbloom-validation-base")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 32:
        parser.error("--jobs must be between 1 and 32")
    if args.workspace_exhaustion and not args.consumer_config:
        parser.error("--workspace-exhaustion requires --consumer-config")
    if args.second_account and not args.consumer_config:
        parser.error("--second-account requires --consumer-config")
    if (args.prepare_base or args.two_vms) and not (args.lume and args.storage):
        parser.error("VM stages require explicit --lume and --storage")
    if args.prepare_base and not args.ipsw:
        parser.error("--prepare-base requires --ipsw")
    if args.storage and (not args.storage.is_absolute() or args.storage.is_symlink()):
        parser.error("--storage must be an absolute path to a dedicated VM directory")
    output = new_directory(args.output)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("DARKBLOOM_SANDBOX_")}
    environment["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"] = "1"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    swift = ["xcrun", "swift", "test", "--package-path", str(PACKAGE), "-j", str(args.jobs)]
    stages = [
        ("release_tool_contracts", [sys.executable, str(PACKAGE / "Scripts/test-sandbox-release-tools.py")], {}),
        ("consumer_harness_contracts", [sys.executable, str(PACKAGE / "Scripts/test-sandbox-live-tools.py")], {}),
        ("benchmark_contracts", [sys.executable, str(PACKAGE / "Scripts/test-sandbox-benchmarks.py")], {}),
        ("ci_benchmark_contracts", [sys.executable, str(PACKAGE / "Scripts/test-sandbox-ci.py")], {}),
        ("ci_benchmark_runner_contracts", [sys.executable, str(PACKAGE / "Scripts/test-sandbox-ci-runner.py")], {}),
        ("publication_contracts", ["/bin/bash", str(PACKAGE / "Scripts/run-lume-publication-contract-tests.sh")], {}),
        ("host_runtime_ownership", ["xcrun", "swift", "test", "--package-path", str(PACKAGE.parent / "host-runtime"), "-j", str(args.jobs)], {}),
        ("swift_unit", swift, {}),
    ]
    if args.coordinator:
        stages.append(("coordinator_sandbox", ["go", "test", "-race", "./sandboxcontrol", "./sandboxhost", "./store", "./protocol", "./api"], {}))
    if args.lume:
        stages.append(("lume_binary", swift + ["--filter", "testPinnedRealLumeBinaryAndEmptyStorageContract"],
                       {"DARKBLOOM_SANDBOX_LUME_PATH": str(args.lume.absolute())}))
    if args.live_restore:
        stages.append(("apple_restore_catalog", swift + ["--filter", "testLatestSupportedRestoreImageAgainstAppleCatalog"],
                       {"DARKBLOOM_SANDBOX_LIVE_RESTORE": "1"}))
    vm_environment = {"DARKBLOOM_SANDBOX_LUME_PATH": str(args.lume),
                      "DARKBLOOM_SANDBOX_VM_STORAGE": str(args.storage),
                      "DARKBLOOM_SANDBOX_BASE_NAME": args.base_name}
    if args.prepare_base:
        stages.append(("base_image", swift + ["--filter", "testPrepareRealMacOSBaseImage"],
                       {**vm_environment, "DARKBLOOM_SANDBOX_LIVE_VM": "1",
                        "DARKBLOOM_SANDBOX_IPSW_PATH": str(args.ipsw.absolute())}))
    if args.two_vms:
        stages.append(("two_vm_lifecycle", swift + ["--filter", "testRunTwoIsolatedMacOSClones"],
                       {**vm_environment, "DARKBLOOM_SANDBOX_LIVE_TWO_VMS": "1"}))
    if args.consumer_config:
        command = [sys.executable, "-B", str(PACKAGE / "Scripts/test-sandbox-live.py"),
                   "--config", str(args.consumer_config.absolute()), "--output", str(output / "consumer")]
        if args.workspace_exhaustion:
            command.append("--workspace-exhaustion")
        if args.second_account:
            command.append("--second-account")
        stages.append(("consumer_acceptance", command, {}))
    initial_digest = source_digest()
    record = {
        "schema_version": 1, "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source_commit": run(["git", "-C", PACKAGE, "rev-parse", "HEAD"],
                             capture_output=True, text=True).stdout.strip(),
        "source_digest_before": initial_digest,
        "host": {"system": platform.system(), "release": platform.release(),
                 "machine": platform.machine()},
        "stages": [], "production_ready": False,
        "not_covered": ["production deployment", "notarization", "persistent keychain",
                        "tenant network policy beyond the selected live probes", "disk quota exhaustion",
                        "cross-host recovery", "physical host inventory after consumer deletion"],
    }
    failed = False
    for name, command, additions in stages:
        if failed:
            record["stages"].append({"name": name, "status": "not_run_after_failure"})
            continue
        log = output / (name + ".log")
        start = time.monotonic()
        print(f"Running {name}; log: {log}", flush=True)
        cwd = PACKAGE.parent / "coordinator" if name.startswith("coordinator") else PACKAGE.parent
        with log.open("x") as stream:
            try:
                process = subprocess.run(command, cwd=cwd, env={**environment, **additions},
                                         stdout=stream, stderr=subprocess.STDOUT)
                code = process.returncode
            except OSError as error:
                stream.write(str(error) + "\n")
                code = 127
        failed = code != 0
        text = log.read_text(errors="replace")
        record["stages"].append({
            "name": name, "status": "failed" if failed else "passed",
            "exit_code": code, "seconds": round(time.monotonic() - start, 3),
            "command": command, "log": log.name, "log_sha256": sha256(log),
            "skip_mentions": sum("skip" in line.lower() for line in text.splitlines()),
        })
    record["source_digest_after"] = source_digest()
    consumer_summary = output / "consumer/summary.json"
    if args.consumer_config and consumer_summary.is_file():
        consumer = json.loads(consumer_summary.read_text())
        record["consumer_evidence"] = {"summary": "consumer/summary.json", "sha256": sha256(consumer_summary),
                                       "selected_cases_passed": consumer.get("passed") is True,
                                       "evidence_scope": consumer.get("evidence_scope"),
                                       "not_covered": consumer.get("not_covered", [])}
        if any(case.get("case") == "workspace_exhaustion" and case.get("status") == "passed"
               for case in consumer.get("cases", [])):
            record["not_covered"].remove("disk quota exhaustion")
    record["source_changed_during_validation"] = record["source_digest_after"] != initial_digest
    record["selected_stages_passed"] = not failed
    record["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    for name, enabled in [("lume_binary", args.lume), ("apple_restore_catalog", args.live_restore),
                          ("base_image", args.prepare_base), ("two_vm_lifecycle", args.two_vms),
                          ("consumer_acceptance", args.consumer_config)]:
        if not enabled:
            record["not_covered"].append(name)
    write_json(output / "evidence.json", record)
    print(json.dumps({"evidence": str(output / "evidence.json"),
                      "selected_stages_passed": not failed, "production_ready": False}))
    return 1 if failed or record["source_changed_during_validation"] else 0


if __name__ == "__main__":
    sys.exit(main())
