"""Bounded single-slot rebuild of an already composed source manifest."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import subprocess
import time
from build_timestamp import ROOT, WORK, digest, record

def main():
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--name', required=True)
    p.add_argument('--sources', required=True)
    args = p.parse_args()
    assert args.name and all(c.isalnum() or c in '-_' for c in args.name)
    manifest = ROOT / 'build' / args.sources
    source = json.loads(manifest.read_bytes())
    for row in source['files']:
        assert record(WORK / row['path'], WORK) == row
    command = json.loads((ROOT / 'build/timestamp-build.json').read_bytes())['argv']
    started = time.monotonic()
    log = ROOT / 'build' / (args.name + '.log')
    with log.open('xb') as stream:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=600)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
            raise
    try:
        os.killpg(process.pid, 0)
        absent = False
    except ProcessLookupError:
        absent = True
    for row in source['files']:
        assert record(WORK / row['path'], WORK) == row
    binary = WORK / 'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release/GemmaResidentBenchmark'
    result = dict(argv=command, exitCode=code, elapsedSeconds=time.monotonic()-started,
        compilerReaped=True, groupAbsent=absent, logSHA256=digest(log),
        sourcesSHA256=digest(manifest), gpuExecuted=False)
    if code == 0:
        result.update(nativeSHA256=digest(binary), nativeBytes=binary.stat().st_size)
    with (ROOT / 'build' / (args.name + '.json')).open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps(result), flush=True)
    assert code == 0 and absent

if __name__ == '__main__':
    main()
