#!/usr/bin/env python3
"""Consumer acceptance against an explicitly configured nonproduction deployment.

Example (does not set up services):
  DARKBLOOM_API_KEY=... python3 -B test-sandbox-live.py --config lab.json --output NEW_DIRECTORY
The full suite waits for the coordinator's real 30-minute expiry. Credentials
are read only from the environment and are never written to evidence or argv.
"""

import argparse
import json
import os
from pathlib import Path

from sandbox_live_evidence import EvidenceCLI
from sandbox_live_suite import LiveSuite


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path, help="explicit nonproduction JSON configuration")
    parser.add_argument("--output", required=True, type=Path, help="new private evidence directory")
    parser.add_argument("--workspace-exhaustion", action="store_true",
                        help="fill one created guest workspace to ENOSPC, clean its unique file, and verify recovery")
    args = parser.parse_args()
    os.umask(0o077)
    config = json.loads(args.config.read_text())
    if args.workspace_exhaustion:
        config["workspace_exhaustion"] = True
    client = EvidenceCLI(config, args.output, os.environ.get("DARKBLOOM_API_KEY", ""))
    passed = LiveSuite(client).run()
    print(json.dumps({"passed": passed, "evidence": str(client.root / "summary.json")}))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
