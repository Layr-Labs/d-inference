#!/usr/bin/env python3
"""Root-run adapter over the exact bounded owner/alias/cleanup parent."""
import argparse
from pathlib import Path
import sys
from prepare_configuration import BASE, CASES, RESEARCH, REMOTE

def configure_parent(name):
    if name not in CASES:
        raise ValueError('Unknown closed candidate case')
    sys.path.insert(0, str(BASE / 'parent'))
    import run_physical
    run_physical.BASE = BASE / 'cases' / name
    run_physical.ROOT = RESEARCH
    run_physical.REMOTE = REMOTE + '/' + name
    run_physical.OUTPUT = run_physical.BASE / 'physical-1'
    run_physical.CONTROLLER = (BASE / 'timing/runtime/owner-timing-controller' if name.endswith('-timing')
        else RESEARCH / 'owner-retirement-controls-build-20260915/bundle-mtp/owner-controller')
    return run_physical

def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--case', required=True, choices=tuple(CASES))
    args = parser.parse_args()
    configure_parent(args.case).main()

if __name__ == '__main__':
    main()
