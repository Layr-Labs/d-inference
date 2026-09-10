"""CLI for read-only startup observations and opt-in disposable-test inference."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re

from .http_probe import TestProbe, validate_base_url
from .observer import Observer, Settings


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise argparse.ArgumentTypeError("timestamp must be ISO 8601 with an explicit timezone") from error
    if parsed.tzinfo is None:
        raise argparse.ArgumentTypeError("timestamp requires an explicit timezone")
    return parsed.astimezone(timezone.utc)


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--base-url", required=True, help="one coordinator origin; default mode sends GET requests only")
    cli.add_argument("--expected-build-commit", required=True, help="exact build_commit emitted by candidate /health")
    cli.add_argument("--model", action="append", required=True, help="exact capacity model ID; repeat for each model to qualify")
    cli.add_argument("--process-started-at", type=timestamp, required=True, help="authoritative process/container start timestamp")
    cli.add_argument("--old-process-stopped-at", type=timestamp, help="old process stop timestamp; excludes its preceding drain")
    cli.add_argument("--duration", type=float, default=180)
    cli.add_argument("--interval", type=float, default=0.5)
    cli.add_argument("--request-timeout", type=float, default=2)
    cli.add_argument("--output", type=Path, required=True, help="new JSON report path (existing files are not overwritten)")
    cli.add_argument("--allow-test-inference", action="store_true", help="authorize bounded synthetic requests ONLY to a configured disposable test environment")
    cli.add_argument("--test-inference-config", type=Path, help="disposable-test JSON config; API key stays in the named environment variable")
    return cli


def main(argv=None):
    cli = parser()
    args = cli.parse_args(argv)
    try:
        base_url = validate_base_url(args.base_url)
        if not re.fullmatch(r"[0-9a-f]{7,40}", args.expected_build_commit):
            raise ValueError("expected build must be a 7-40 character lowercase hexadecimal commit")
        if len(args.model) > 16 or len(set(args.model)) != len(args.model) or any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9/_.:-]{0,159}", model) for model in args.model):
            raise ValueError("provide 1-16 unique exact model IDs using letters, numbers and /_.:-")
        if not (0 < args.duration <= 3600 and 0.25 <= args.interval <= 60 and 0.1 <= args.request_timeout <= 10):
            raise ValueError("duration must be (0,3600], interval [0.25,60], request timeout [0.1,10] seconds")
        if args.process_started_at > datetime.now(timezone.utc):
            raise ValueError("process start timestamp cannot be in the future")
        if args.old_process_stopped_at and args.old_process_stopped_at > args.process_started_at:
            raise ValueError("old process stop must precede or equal candidate process start")
        if args.allow_test_inference != bool(args.test_inference_config):
            raise ValueError("test inference requires BOTH --allow-test-inference and --test-inference-config")
        probe = TestProbe.from_file(args.test_inference_config, base_url) if args.allow_test_inference else None
        settings = Settings(base_url, args.expected_build_commit, args.model, args.process_started_at,
                            args.old_process_stopped_at, args.duration, args.interval, args.request_timeout)
        # Reserve the path before network IO, avoiding an expensive run whose
        # output would overwrite another report. Report contains no credentials.
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except (ValueError, OSError, TypeError) as error:
        cli.error(str(error))
    with os.fdopen(fd, "w", encoding="utf-8") as destination:
        report = Observer(settings, probe=probe).run()
        json.dump(report, destination, indent=2, allow_nan=False)
        destination.write("\n")
    print(json.dumps({key: report[key] for key in ("mode", "measurement_target_reached", "inference_verified", "correctness")}))
    if report["correctness"] == "failed":
        return 3
    return 0 if report["measurement_target_reached"] else 1
