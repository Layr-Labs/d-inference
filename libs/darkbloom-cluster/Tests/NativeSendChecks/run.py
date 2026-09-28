"""Exercise current JACCL send headers with fake verbs and actual completions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
NATIVE = REPO / 'libs/mlx-swift/Source/Cmlx/mlx/mlx/distributed/jaccl/lib'
sys.path.insert(0, str(HERE.parent / 'SecurityChecks'))
from run import run_owned


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, exist_ok=False)
    original = HERE / 'OriginalHeaders'
    sources = [HERE / name for name in ('Main.cpp', 'FakeRDMA.cpp', 'PointToPoint.cpp', 'Collectives.cpp')]
    paths = [NATIVE / 'jaccl' / name for name in
             ('send_frame.h', 'rdma.h', 'mesh_impl.h', 'ring_impl.h', 'tcp.h', 'threadpool.h')]
    paths += [path for path in HERE.rglob('*') if path.is_file()]
    paths += [HERE.parent / 'SecurityChecks' / name for name in ('run.py', 'owned_process.py')]
    def snapshot():
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    before = snapshot()
    (output / 'source-snapshot.json').write_text(json.dumps(before, indent=2, sort_keys=True) + '\n')
    common = ['xcrun', 'clang++', '-std=c++20', '-O1', '-g', '-pthread',
              '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(HERE / 'stubs')]
    candidate = common + ['-I', str(NATIVE)] + list(map(str, sources)) + ['-o', str(output / 'candidate')]
    baseline = common + ['-DEXPECT_ORIGINAL_STALE_TAIL', '-I', str(original), '-I', str(NATIVE)]
    baseline += list(map(str, sources)) + ['-o', str(output / 'original')]
    steps = [('candidate-compile', candidate, 60), ('candidate-check', [str(output / 'candidate')], 10),
             ('original-compile', baseline, 60), ('original-regression', [str(output / 'original')], 10)]
    receipts = []
    try:
        for name, argv, timeout in steps:
            if snapshot() != before:
                raise ValueError('Source changed before native header check')
            receipts.append(run_owned(argv, output, name, timeout))
    finally:
        if snapshot() != before:
            raise ValueError('Source changed during native header check')
    (output / 'checks.json').write_text(json.dumps({'passed': True, 'steps': receipts,
        'sourceUnchanged': True, 'actualHeaders': True, 'verbsAreFake': True,
        'nativeRDMAExecuted': False, 'modelOrGPUExecuted': False}, indent=2) + '\n')
    print((output / 'candidate-check.stdout').read_text(), end='')
    print((output / 'original-regression.stdout').read_text(), end='')


if __name__ == '__main__':
    os.umask(0o077)
    main()
