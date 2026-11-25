"""Single-slot jobs=2 native build; source-pinned, bounded and reaped."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent
WORK = ROOT.parent / 'gemma4-execution-20260920/build/workspace'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--name', required=True)
    parser.add_argument('--sources', required=True, type=Path)
    args = parser.parse_args()
    assert args.name and all(c.isalnum() or c in '-_' for c in args.name)
    inputs = json.loads(args.sources.read_bytes())
    def verify():
        for row in inputs['files']:
            path = WORK / row['path']
            assert sha(path) == row['sha256'] and path.stat().st_size == row['bytes'], row['path']
    verify()
    base = ROOT.parent / 'gemma4-decode-optimization-20260920/build/timestamp-build.json'
    command = json.loads(base.read_bytes())['argv'] + ['-Xswiftc', '-DCBV2_WINDOW_STATE_FIXTURE']
    log = ROOT / 'build' / (args.name + '.log')
    started = time.monotonic()
    with log.open('xb') as stream:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=600)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=10)
            raise
    try:
        os.killpg(process.pid, 0); absent = False
    except ProcessLookupError:
        absent = True
    verify()
    binary = WORK / 'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release/GemmaResidentBenchmark'
    result = dict(argv=command, exitCode=code, elapsedSeconds=time.monotonic()-started,
                  compilerReaped=True, groupAbsent=absent, logSHA256=sha(log),
                  sourcesSHA256=sha(args.sources), gpuExecuted=False)
    if code == 0:
        result.update(nativeSHA256=sha(binary), nativeBytes=binary.stat().st_size)
    with (ROOT / 'build' / (args.name + '.json')).open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps(result), flush=True)
    assert code == 0 and absent


if __name__ == '__main__':
    main()
