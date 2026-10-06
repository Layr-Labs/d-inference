#!/usr/bin/env python3
"""Build a committed qualification candidate from clean products and retain proof."""
import argparse
import fcntl
from pathlib import Path
import tempfile

from serving_performance.exclusive_host import foreign_work
from serving_performance.qualification_build import build_candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new directory for build record and log")
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    args = parser.parse_args()
    if not 1 <= args.timeout_seconds <= 7200:
        parser.error("build timeout must be1...7200 seconds")
    with open(Path(tempfile.gettempdir()) / "darkbloom-serving-qualification.lock", "a+") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if foreign_work():
            parser.error("dedicated qualification host is busy")
        result = build_candidate(Path(__file__).resolve().parent.parent, args.output.resolve(),
                                 timeout=args.timeout_seconds)
        print(result)


if __name__ == "__main__":
    main()
