"""After an explicit compiler grant: bounded actual-header CPU regression."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from check_process import run_owned

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
RELATIVE = Path('libs/mlx-swift/Source/Cmlx/mlx/mlx/distributed/jaccl/lib')


def verify():
    rows = json.loads((ROOT / 'manifest.json').read_text())['files']
    for row in rows:
        if hashlib.sha256((ROOT / row['path']).read_bytes()).hexdigest() != row['sha256']:
            raise ValueError('Frozen source differs: ' + row['path'])
    return len(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    count = verify()
    output = args.output.resolve()
    output.mkdir(mode=0o700, exist_ok=False)
    proposed, original = ROOT / 'proposed' / RELATIVE, ROOT / 'originals' / RELATIVE
    sources = [str(HERE / name) for name in ('Main.cpp', 'FakeRDMA.cpp', 'PointToPoint.cpp', 'Collectives.cpp')]
    common = ['xcrun', 'clang++', '-std=c++20', '-O1', '-g', '-pthread',
              '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(HERE / 'stubs')]
    candidate = common + ['-I', str(proposed), '-I', str(original)] + sources + ['-o', str(output / 'candidate')]
    baseline = common + ['-DEXPECT_ORIGINAL_STALE_TAIL', '-I', str(original), '-I', str(proposed)] + sources + ['-o', str(output / 'original')]
    steps = [('candidate-compile', candidate, 60), ('candidate-check', [str(output / 'candidate')], 10),
             ('original-compile', baseline, 60), ('original-regression', [str(output / 'original')], 10)]
    receipts = []
    print('Tail regression runner PID ' + str(os.getpid()), flush=True)
    for name, argv, timeout in steps:
        verify()
        print('Starting ' + name, flush=True)
        try:
            receipts.append(run_owned(argv, output, name, timeout))
        finally:
            verify()
        print('Completed ' + name, flush=True)
    (output / 'checks.json').write_text(json.dumps({'passed': True, 'steps': receipts,
        'sourceMembersUnchanged': count, 'actualHeaders': True, 'verbsAreFake': True,
        'nativeRDMAExecuted': False, 'modelOrGPUExecuted': False}, indent=2) + '\n')


if __name__ == '__main__':
    main()
