#!/usr/bin/env python3
"""Read-only startup observer; synthetic inference requires a disposable-test config."""
from startup_measurement.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
