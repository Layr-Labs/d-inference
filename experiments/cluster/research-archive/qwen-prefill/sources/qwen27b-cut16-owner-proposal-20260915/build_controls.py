"""Two bounded Foundation builds and one model-free metadata invocation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time

BASE = Path(__file__).resolve().parent
UPSTREAM = BASE.parent / 'qwen27b-owner-load-operands-rerun-20260915'
sys.path.insert(0, str(UPSTREAM))
from copy_owned import invoke_controller


def pin(path):
    raw = path.read_bytes()
    return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def main():
    frozen = json.loads((BASE / 'build-preparation-manifest.json').read_bytes())
    for item in frozen['inputs']:
        assert pin(Path(item['path'])) == item, item['path']
    commands = json.loads((BASE / 'future-commands.json').read_bytes())
    output = BASE / 'build-1'
    output.mkdir(mode=0o700)
    for name, key in [('owner', 'ownerCompile'), ('metadata', 'metadataCompile')]:
        destination = output / name
        destination.mkdir(mode=0o700)
        argv = commands[key]
        dependency = Path(argv[argv.index('-L') + 1])
        for path in sorted(dependency.glob('*.dylib')):
            if name == 'metadata' and path.name != 'libDarkbloomClusterProtocol.dylib':
                continue
            shutil.copy2(path, destination / path.name)
    result = dict(passed=False, compilerMaxJobs=2, nativeWorkerOrModelOrRemoteExecuted=False, operations=[])
    began = time.monotonic()
    print(json.dumps(dict(runnerPID=os.getpid(), output=str(output))), flush=True)
    try:
        for name, key, limit in [('owner-build', 'ownerCompile', 90),
                                  ('metadata-build', 'metadataCompile', 90),
                                  ('metadata', 'metadataExecute', 30)]:
            directory = output / (name + '-evidence')
            directory.mkdir(mode=0o700)
            receipt = dict(argv=commands[key], timeoutSeconds=limit, name=name)
            start = time.monotonic()
            print(json.dumps(dict(starting=name, timeoutSeconds=limit)), flush=True)
            try:
                with (directory / 'stdout').open('xb') as stdout, (directory / 'stderr').open('xb') as stderr:
                    invoke_controller(commands[key], stdout, stderr, receipt, timeout=limit)
                assert receipt['exitCode'] == 0 and receipt['reaped'] and receipt['groupAbsent']
                assert not (directory / 'stderr').read_bytes()
                receipt['passed'] = True
            finally:
                receipt.update(elapsedSeconds=time.monotonic() - start,
                               stdout=pin(directory / 'stdout'), stderr=pin(directory / 'stderr'))
                write(directory / 'receipt.json', receipt)
                result['operations'].append(receipt)
            print(json.dumps(dict(completed=name, seconds=receipt['elapsedSeconds'], passed=True)), flush=True)
        metadata = json.loads((output / 'metadata-evidence/stdout').read_bytes())
        assert metadata['stageCut'] == 16 and metadata['canonicalCounts'] == [463, 1384]
        assert metadata['activeBytes'] == [4_140_778_752, 10_992_023_296]
        assert metadata['nativeBinarySHA256'] == '989f701ca6a8178ebc41b73e840a937c17aa9b0a3f8a53b9fee8432a4cd5ffdb'
        assert metadata['modelPayloadRead'] is False and metadata['nativeExecuted'] is False
        result.update(passed=True, metadata=pin(output / 'metadata-evidence/stdout'),
                      owner=pin(output / 'owner/darkbloom-owner-qualification'))
    finally:
        result['elapsedSeconds'] = time.monotonic() - began
        result['inputPinsUnchanged'] = all(pin(Path(item['path'])) == item for item in frozen['inputs'])
        write(output / 'result.json', result)
    assert result['passed'] and result['inputPinsUnchanged']
    print(json.dumps(dict(passed=True, owner=result['owner'], metadata=result['metadata'])), flush=True)


if __name__ == '__main__':
    main()
