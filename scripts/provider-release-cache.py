#!/usr/bin/env python3
"""Key unsigned build caches and preserve content-verified source timestamps.

Run keys after selecting the provider toolchain; redirect its scalar output to
GITHUB_OUTPUT. Run restore-mtimes after restoring .build, then snapshot-mtimes
after compiling and before saving .build. No signed bundle or credentials belong
in these caches. The release lane does not inspect or emit Rust cache identity.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys

from provider_release_cache.identity import keys
from provider_release_cache.mtimes import restore, snapshot


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    for name in ("keys", "snapshot-mtimes", "restore-mtimes"):
        command = subcommands.add_parser(name)
        command.add_argument("--root", type=Path, default=Path.cwd())
        if name == "keys":
            command.add_argument("--lane", choices=("release", "qualification"), required=True)
    args = parser.parse_args()
    try:
        if args.command == "keys":
            for name, value in keys(args.root, args.lane).items():
                # Output only selected public metadata and digest values. Never
                # let a version string insert additional GitHub output records.
                value = " ".join(str(value).split())
                print(f"{name}={value}")
        else:
            operation = snapshot if args.command == "snapshot-mtimes" else restore
            print(json.dumps(operation(args.root), sort_keys=True))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Provider release cache: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
