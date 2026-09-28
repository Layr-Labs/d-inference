#!/usr/bin/env python3
"""Run bounded local P2P and verified whole-layer stage correctness checks."""

import sys
from runtime.stage_checks.cli import main


if __name__ == '__main__':
    sys.exit(main())
