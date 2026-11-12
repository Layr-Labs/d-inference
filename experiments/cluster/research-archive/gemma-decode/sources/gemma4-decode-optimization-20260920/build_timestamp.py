"""Restore the accepted benchmark composition, preserve EP, change only UTC formatting."""
from pathlib import Path
import hashlib
import json
import os
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent / 'gemma4-execution-20260920'
WORK = BASE / 'build/workspace'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def record(path, root):
    return dict(path=str(path.relative_to(root)), bytes=path.stat().st_size, sha256=digest(path))

def main():
    prior_path = BASE / 'build/applied-uncached-sidecars.json'
    ep_path = BASE / 'build/applied-full-model-ep.json'
    assert digest(prior_path) == '8ec41c24385edfa16b66864ffbf4161de470dbb5b5c559d8a134243b102288a6'
    prior, ep = json.loads(prior_path.read_bytes()), json.loads(ep_path.read_bytes())
    for row in ep['files']:
        assert record(WORK / row['path'], WORK) == row, row['path']
    destinations = sorted({x['destination'] for x in ep['fullExpertOverlaySteps']})
    preserve = ROOT / 'build/preserved-ep'
    preserve.mkdir(mode=0o700)
    restoration = []
    for name in destinations:
        target = WORK / name
        backup = preserve / name
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_bytes(target.read_bytes())
        original = BASE / 'build/before-full-model-ep' / name
        restoration.append(dict(path=name, expertSHA256=digest(target),
            restoredSHA256=digest(original) if original.exists() else None))
    # Every replacement/new file was retained above before restoring the prior composition.
    for row in restoration:
        target = WORK / row['path']
        original = BASE / 'build/before-full-model-ep' / row['path']
        if original.exists():
            target.write_bytes(original.read_bytes())
        else:
            target.unlink()
    for row in prior['files']:
        assert record(WORK / row['path'], WORK) == row, row['path']
    runtime = WORK / 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    source = runtime / 'QwenDenseStageLoadResources.swift'
    before = source.read_bytes()
    anchor = b'ISO8601DateFormatter().string(from: Date())'
    assert before.count(anchor) == 1
    (ROOT / 'build/QwenDenseStageLoadResources.before.swift').write_bytes(before)
    after = before.replace(anchor, b'ResourceObservationTimestamp.utc()')
    helper = runtime / 'ResourceObservationTimestamp.swift'
    assert not helper.exists()
    source.write_bytes(after)
    helper.write_bytes((ROOT / 'Sources/ResourceObservationTimestamp.swift').read_bytes())
    assert source.read_bytes().replace(b'ResourceObservationTimestamp.utc()', anchor) == before
    files = {row['path'] for row in prior['files']} | {str(source.relative_to(WORK)), str(helper.relative_to(WORK))}
    composition = dict(baselineSourcesSHA256=digest(prior_path), expertSourcesSHA256=digest(ep_path),
        expertRestoration=restoration, changes=['UTC formatter reuse only'],
        unchanged='All fresh OS/native/power reads, guard calls, floors, fences and model math',
        files=[record(WORK / p, WORK) for p in sorted(files)])
    receipt = ROOT / 'build/applied-timestamp.json'
    receipt.write_text(json.dumps(composition, indent=2)+'\n')
    package = WORK / 'libs/darkbloom-cluster-worker'
    command = ['/usr/bin/swift', 'build', '--package-path', str(package), '--scratch-path',
        str(package / '.build-native-worker'), '-c', 'release', '--jobs', '2',
        '--disable-automatic-resolution', '--skip-update', '--disable-build-manifest-caching',
        '--triple', 'arm64-apple-macosx26.2', '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2',
        '--product', 'GemmaResidentBenchmark']
    started = time.monotonic()
    log = ROOT / 'build/timestamp-build.log'
    with log.open('xb') as stream:
        p = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                             stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = p.wait(timeout=600)
        except BaseException:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait(timeout=10)
            raise
    try:
        os.killpg(p.pid, 0)
        absent = False
    except ProcessLookupError:
        absent = True
    for row in composition['files']:
        assert record(WORK / row['path'], WORK) == row
    binary = package / '.build-native-worker/arm64-apple-macosx/release/GemmaResidentBenchmark'
    result = dict(argv=command, exitCode=code, elapsedSeconds=time.monotonic()-started,
        reaped=True, groupAbsent=absent, logSHA256=digest(log), sourcesSHA256=digest(receipt),
        gpuExecuted=False)
    if code == 0:
        result['nativeSHA256'] = digest(binary)
        result['nativeBytes'] = binary.stat().st_size
    (ROOT / 'build/timestamp-build.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result), flush=True)
    assert code == 0 and absent

if __name__ == '__main__':
    main()
