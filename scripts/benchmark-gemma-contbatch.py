#!/usr/bin/env python3
"""Run and report the reproducible Gemma continuous-batching benchmark."""

import subprocess
import sys

from gemma_contbatch.runner import main


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
