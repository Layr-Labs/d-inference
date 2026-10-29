"""Bounded sequential CLI tests/build using the already reviewed process runner."""
import argparse
import json
import os
from pathlib import Path
import sys
from stage_overlay import HERE, inputs

sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    values, source = inputs()
    workspace = Path(values['workspace'])
    expected = json.loads((HERE / 'staged/source-snapshot.json').read_text())
    sys.path.insert(0, str(Path(values['helpers'][1]['path']).parent))
    from check_process import run_owned
    out = args.output.resolve()
    out.mkdir(mode=0o700, exist_ok=False)
    steps = [
        ('cli-tests', ['swift', 'test', '-j', '2', '--disable-automatic-resolution',
            '--disable-build-manifest-caching', '--filter',
            'DistributedStartSessionFactoryTests|DistributedStartCommandTests|DistributedLocalRotation'], 900),
        ('cli-build', ['swift', 'build', '-j', '2', '--disable-automatic-resolution',
            '--disable-build-manifest-caching', '--product', 'darkbloom'], 900),
    ]
    receipts = []
    print('CLI check runner PID ' + str(os.getpid()), flush=True)
    os.chdir(workspace / 'provider-swift')
    for name, command, timeout in steps:
        if source.inventory(workspace) != expected:
            raise ValueError('Source/dependency changed before step')
        print('Starting ' + name, flush=True)
        try:
            receipts.append(run_owned(command, out, name, timeout))
        finally:
            if source.inventory(workspace) != expected:
                raise ValueError('Source/dependency changed during step')
            (out / (name + '-source-recheck.json')).write_text(json.dumps({
                'unchanged': True, 'sourceDependencyCount': len(expected)}, indent=2) + '\n')
        print('Completed ' + name, flush=True)
    (out / 'checks.json').write_text(json.dumps({'passed': True, 'steps': receipts,
        'nativeModelExecuted': False, 'remoteExecuted': False, 'mainMutated': False}, indent=2) + '\n')


if __name__ == '__main__':
    main()
