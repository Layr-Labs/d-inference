"""Bound the three exact preparation helpers; no retries or partial-tree cleanup."""
import os
import sys
from build_inputs import BASE, inputs
from check_process import run_owned


def main():
    names = {'sources': 'prepare_sources.py', 'cache': 'prepare_cache.py', 'snapshot': 'snapshot_build.py'}
    if len(sys.argv) != 2 or sys.argv[1] not in names:
        raise ValueError('Expected sources, cache or snapshot')
    phase = sys.argv[1]
    inputs()
    output = BASE / ('preparation-' + phase)
    output.mkdir(mode=0o700)
    run_owned([sys.executable, '-B', str(BASE / names[phase])], output, phase, 180)
    print('Preparation ' + phase + ' PASS; no compiler/model/remote execution', flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
