"""Stage a validated packet, then optionally run the reviewed standalone probe."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

from attention_packet.files import digest, read_bounded, require, sha256
from .report import collect
from .transfer import ARMS, prepare


def log_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packet", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--binary-sha256")
    args = parser.parse_args(argv)
    if args.prepare_only:
        require(args.binary is None and args.binary_sha256 is None, "prepare-only cannot select a binary")
    else:
        require(args.binary is not None, "execution requires an explicitly selected probe")
        digest(args.binary_sha256, "probe SHA256")
        args.binary = args.binary.resolve(strict=True)
        require(sha256(read_bounded(args.binary, 256 << 20)) == args.binary_sha256, "probe SHA256 mismatch")
    packet, transfer, transfer_hash = prepare(args.packet, args.output)
    if args.prepare_only:
        return 0
    records = []
    for arm in ARMS:
        command = [str(args.binary), "--input", str((args.output / "input.json").resolve()),
                   "--input-sha256", transfer_hash, "--output", str((args.output / arm).absolute()), "--arm", arm]
        start = time.monotonic()
        failure = None
        exit_code = None
        with (args.output / (arm + ".log")).open("x") as log:
            try:
                completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
                exit_code = completed.returncode
            except (subprocess.TimeoutExpired, OSError) as error:
                # subprocess.run kills and reaps its direct child on timeout.
                failure = type(error).__name__ + ": " + str(error)
        records.append({"arm": arm, "argv": command, "seconds": time.monotonic() - start,
                        "exitCode": exit_code, "failure": failure, "binarySHA256": args.binary_sha256,
                        "logSHA256": None, "logHashError": None})
        # Retain process outcome even if the separate log read fails.
        (args.output / "execution.json").write_text(json.dumps(records, indent=2) + "\n")
        try:
            records[-1]["logSHA256"] = log_sha256(args.output / (arm + ".log"))
        except OSError as error:
            records[-1]["logHashError"] = type(error).__name__ + ": " + str(error)
        (args.output / "execution.json").write_text(json.dumps(records, indent=2) + "\n")
        require(exit_code == 0 and failure is None, "actual replay arm failed; preserved output: " + arm)
        require(records[-1]["logHashError"] is None, "replay log hash failed; process outcome preserved")
        require(sha256(read_bounded(args.binary, 256 << 20)) == args.binary_sha256, "probe changed during replay")
    report = collect(packet, transfer, transfer_hash, args.output)
    report["execution"] = records
    (args.output / "analysis.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
