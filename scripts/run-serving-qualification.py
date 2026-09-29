#!/usr/bin/env python3
"""Collect exact-artifact receipts on explicitly leased, dedicated local hardware.

Build tests and stage the matching metallib before invocation. This supervisor
never builds, downloads, deploys, edits model files, or interrupts other jobs.
"""
import argparse
import fcntl
import hashlib
import json
import os
import random
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid

from serving_performance.live_receipts import summarize
from serving_performance.build_identity import verified_build_identity
from serving_performance.power_posture import read_posture
from serving_performance.exclusive_host import foreign_work
from serving_performance.source_provenance import source_identity as identify_source

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def source_identity():
    return identify_source(ROOT)

def terminate_owned_group(process):
    # Only the session this process created; never pgrep/kill external workers.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--artifact-sha256", required=True, help="verified production WeightHasher aggregate")
    parser.add_argument("--exclusive-gpu-lease", required=True, help="operator/agent lease receipt, stored as a hash")
    parser.add_argument("--prompt-lengths", default="4096,16384,32768")
    parser.add_argument("--prompt-band", help="MIN:MAX; iterations becomes total independent trials including both endpoints")
    parser.add_argument("--output-tokens", type=int, default=128)
    parser.add_argument("--width", type=int, default=1)
    parser.add_argument("--scheduler-max-concurrency", type=int,
                        help="keep actual engine cap fixed while varying submitted request width")
    parser.add_argument("--serving-policy", action="store_true",
                        help="construct the ordinary serving factory policy for deadline-only calibration")
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--mixed-prefill-token-cap", type=int, choices=(128, 256, 512))
    parser.add_argument("--stagger-ms", type=int, default=0)
    parser.add_argument("--reused", action="store_true")
    parser.add_argument("--tool-history", action="store_true")
    parser.add_argument("--lifecycle-checks", action="store_true", help="run actual cancellation/retirement and greedy parity checks")
    parser.add_argument("--partition", choices=("baseline", "calibration", "validation"), default="baseline")
    parser.add_argument("--kv-backend", choices=("auto", "paged", "contiguous"), default="auto")
    parser.add_argument("--build-configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--test-executable", type=Path, help="prebuilt portable Swift Testing executable")
    parser.add_argument("--timeout-seconds", type=int, default=3600)
    parser.add_argument("--output-root", type=Path, default=Path(tempfile.gettempdir()))
    args = parser.parse_args()
    if not (1 <= args.width <= 16 and 1 <= args.iterations <= 1000 and
            1 <= args.output_tokens <= 4096 and 1 <= args.timeout_seconds <= 86400 and args.stagger_ms >= 0):
        parser.error("invalid bounded workload/deadline")
    if args.scheduler_max_concurrency is not None and not args.width <= args.scheduler_max_concurrency <= 16:
        parser.error("scheduler cap must contain the submitted width and be at most 16")
    prompt_lengths = [int(value) for value in args.prompt_lengths.split(",")]
    if not prompt_lengths or any(not 1 <= value <= 1_048_576 for value in prompt_lengths):
        parser.error("invalid prompt lengths")
    band = [int(value) for value in args.prompt_band.split(":")] if args.prompt_band else None
    if band is not None and (len(band) != 2 or not 1 <= band[0] < band[1] <= 1_048_576 or args.iterations < 2):
        parser.error("prompt band requires ordered bounded endpoints and at least two trials")
    path = args.model_path.expanduser().resolve(strict=True)
    members = sorted(p for p in path.iterdir() if p.is_file())
    weights = [p for p in members if p.suffix == ".safetensors"]
    if not weights or not (path / "config.json").is_file():
        parser.error("complete local artifact required; downloads are not permitted")
    # Machine-local cooperative lock supplements the externally granted lease.
    with open(Path(tempfile.gettempdir()) / "darkbloom-serving-qualification.lock", "a+") as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("another dedicated qualification owns the local GPU lock")
        run = Path(tempfile.mkdtemp(prefix="serving-qualification-", dir=args.output_root))
        run_id = str(uuid.uuid4())
        if band:
            rng = random.Random(run_id)
            prompt_lengths = [*band] + [rng.randint(*band) for _ in range(args.iterations - 2)]
        receipt = run / "receipt.json"
        job = dict(modelID=args.model_id, modelPath=str(path), artifactSHA256=args.artifact_sha256,
                   outputPath=str(receipt), promptLengths=prompt_lengths, outputTokens=args.output_tokens,
                   width=args.width, schedulerMaxConcurrentRequests=args.scheduler_max_concurrency,
                   servingPolicy=args.serving_policy, iterations=1 if band else args.iterations,
                   mixedPrefillTokenCap=args.mixed_prefill_token_cap,
                   staggerMilliseconds=args.stagger_ms, reused=args.reused, toolHistory=args.tool_history,
                   partition=args.partition, runID=run_id, kvBackend=args.kv_backend)
        job_path = run / "job.json"
        job_path.write_text(json.dumps(job, indent=2) + "\n")
        before = {p.name: {"bytes": p.stat().st_size, "sha256": digest(p)} for p in members}
        provenance = dict(source=source_identity(), files=before,
                          lease_sha256=hashlib.sha256(args.exclusive_gpu_lease.encode()).hexdigest(),
                          build_configuration=args.build_configuration,
                          qualification_test_graph=True, swift_enable_testing=True)
        provenance["power_posture_before"] = read_posture()
        binaries = ([args.test_executable.resolve(strict=True)] if args.test_executable else
                    sorted((ROOT / "provider-swift/.build").glob(
                        f"**/{args.build_configuration}/*.xctest/Contents/MacOS/*")))
        provenance["test_binaries_sha256"] = {str(p): digest(p) for p in binaries if p.is_file() and os.access(p, os.X_OK)}
        if not provenance["test_binaries_sha256"]:
            parser.error("build the provider tests before acquiring the GPU lease")
        metallibs = {Path(p).parent / "mlx.metallib" for p in provenance["test_binaries_sha256"]}
        if not all(p.is_file() for p in metallibs):
            parser.error("stage the source-matched metallib beside the test binary")
        provenance["metallibs_sha256"] = {str(p): digest(p) for p in sorted(metallibs)}
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(("DARKBLOOM_", "MLX_", "MTPLX_", "QWEN_"))}
        environment.update(DARKBLOOM_SERVING_QUALIFICATION="supervised-v1",
                           DARKBLOOM_SERVING_QUALIFICATION_BUILD="1",
                           DARKBLOOM_SERVING_QUALIFICATION_JOB=str(job_path),
                           HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
        test_filter = "ServingQualificationLiveTests.collectDedicatedReceipts"
        if args.lifecycle_checks:
            environment["DARKBLOOM_SERVING_QUALIFICATION_LIFECYCLE"] = "supervised-v1"
            test_filter = "ServingQualificationLifecycleTests.cancellationRetiresActualWorkAndPreservesGreedyOutput"
        command = ([str(args.test_executable.resolve()), "--testing-library", "swift-testing",
                    "--filter", test_filter]
                   if args.test_executable else ["swift", "test", "--skip-build", "-c", args.build_configuration,
                    "--filter", test_filter])
        print(json.dumps({"run_directory": str(run), "command": command}), flush=True)
        inventory = foreign_work()
        if inventory:
            provenance.update(return_code=125, foreign_work_before=inventory)
            (run / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
            print(json.dumps({"not_started": "dedicated_host_is_busy", "categories": inventory}), flush=True)
            return 125
        with (run / "run.log").open("w") as log:
            process = subprocess.Popen(command, cwd=ROOT / "provider-swift", env=environment,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + args.timeout_seconds
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(command, args.timeout_seconds)
                    try:
                        status = process.wait(timeout=min(1, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        inventory = foreign_work(process.pid)
                        if inventory:
                            provenance["foreign_work_during"] = inventory
                            terminate_owned_group(process)
                            status = 125
                            break
            except subprocess.TimeoutExpired:
                terminate_owned_group(process)
                status = 124
            except BaseException:
                terminate_owned_group(process)
                raise
        after = {p.name: {"bytes": p.stat().st_size, "sha256": digest(p)} for p in members}
        provenance.update(return_code=status, artifact_unchanged=before == after,
                          source_unchanged=provenance["source"] == source_identity(),
                          power_posture_after=read_posture())
        provenance["binary_unchanged"] = all(Path(p).is_file() and digest(Path(p)) == expected
            for p, expected in {**provenance["test_binaries_sha256"], **provenance["metallibs_sha256"]}.items())
        if receipt.is_file():
            try:
                observed_build = verified_build_identity(json.loads(receipt.read_bytes()), provenance,
                    require_release=args.build_configuration == "release")
                provenance["actual_build_identity"] = observed_build
                provenance["debug_compilation_condition"] = observed_build["debugCompilationCondition"]
            except ValueError as error:
                provenance["build_identity_error"] = str(error)
                status = status or 1
                provenance["return_code"] = status
        (run / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        if receipt.is_file():
            collected = json.loads(receipt.read_bytes())
            summary = ({"qualified": False, "kind": "lifecycle", "passed": collected.get("passed", False),
                        "promotion_blockers": ["lifecycle checks alone do not qualify performance"]}
                       if args.lifecycle_checks else summarize(collected))
            if any(provenance[key]["mode"] != "automatic" for key in ("power_posture_before", "power_posture_after")):
                summary["promotion_blockers"].append("measured power policy is not Automatic")
            if provenance["power_posture_before"] != provenance["power_posture_after"]:
                summary["promotion_blockers"].append("power posture changed during collection")
            if provenance.get("foreign_work_during"):
                summary["promotion_blockers"].append("concurrent work invalidated the dedicated hardware lease")
            summary.update(receipt_sha256=digest(receipt), provenance_sha256=digest(run / "provenance.json"))
            (run / "summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n")
        else:
            status = status or 1
        if not all(provenance[key] for key in ("artifact_unchanged", "source_unchanged", "binary_unchanged")):
            return 1
        return status


if __name__ == "__main__":
    raise SystemExit(main())
