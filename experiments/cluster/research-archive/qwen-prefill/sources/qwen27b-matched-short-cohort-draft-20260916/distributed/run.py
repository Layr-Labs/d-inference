"""Root-only invocation of the unchanged frozen physical parent, with a new pinned config/output."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent
OLD = BASE.parent.parent / 'qwen27b-matched-distributed-timing-20260915'


def verify():
    assert hashlib.sha256((OLD/'manifest.json').read_bytes()).hexdigest() == '4bc3f946d7aca899981d1bb213f7c1eb58760e1270223ce12888e08889d59156'
    manifest = json.loads((OLD/'manifest.json').read_bytes())
    for name, row in manifest['files'].items():
        path = OLD/name
        assert not path.is_symlink() and path.stat().st_size == row['bytes']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256']
    for row in json.loads((BASE/'manifest.json').read_bytes())['files']:
        path = BASE/row['path']
        assert not path.is_symlink() and path.stat().st_size == row['bytes']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256']


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--case', required=True, choices=[p+'-'+str(i) for p in ('serial','lookahead') for i in (1,2,3)])
    args = parser.parse_args()
    verify()
    row, = [x for x in json.loads((BASE/'configurations.json').read_bytes())['configurations'] if x['case'] == args.case]
    parent = OLD/row['policy']
    sys.path.insert(0, str(parent))
    spec = importlib.util.spec_from_file_location('frozen_physical_parent', parent/'run_physical.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    # ROOT, REMOTE, controller, all ownership/alias/resource helpers remain frozen.
    # BASE selects only the new configuration/run-pins; OUTPUT is create-only.
    module.BASE = BASE/args.case
    module.OUTPUT = module.BASE/'physical-1'
    module.main()


if __name__ == '__main__':
    main()
