from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .processor import Processor, ProcessorConfig


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="darkbloom-analytics",
        description="Convert finalized Darkbloom job events into local Parquet analytics.",
    )
    result.add_argument(
        "--root",
        type=Path,
        default=Path.home() / ".darkbloom" / "analytics",
        help="Analytics workspace (default: ~/.darkbloom/analytics)",
    )
    subcommands = result.add_subparsers(dest="command", required=True)
    subcommands.add_parser("init", help="Create the workspace and install the Rill project")
    subcommands.add_parser("run", help="Process all eligible completed UTC hours and exit")
    subcommands.add_parser("status", help="Print processor state as JSON")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    processor = Processor(ProcessorConfig(root=args.root))
    try:
        if args.command == "init":
            processor.initialize()
            print(f"Initialized {processor.root}")
        elif args.command == "run":
            result = processor.run()
            print(json.dumps({
                "processed_hours": result.processed_hours,
                "quarantined_files": result.quarantined_files,
            }, indent=2))
        else:
            print(json.dumps(processor.status(), indent=2, sort_keys=True))
    except Exception as exc:
        print(f"darkbloom-analytics: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
