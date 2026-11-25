"""Package only a successful build and its exact inherited resources; never launch it."""
import json
import os
import shutil
import sys
from build_inputs import BASE, OLD, CACHE, sha, verify


def main():
    attempt, = sys.argv[1:]
    if not attempt.isdecimal() or not 1 <= int(attempt) <= 99:
        raise ValueError('Expected successful numeric build attempt')
    run = BASE / ('native-' + attempt)
    receipt = json.loads((run / 'receipt.json').read_bytes())
    if receipt.get('passed') is not True or len(receipt['steps']) != 3:
        raise RuntimeError('Successful bounded native build is required')
    verify()
    directory = CACHE / 'arm64-apple-macosx/release'
    binary = directory / 'darkbloom-cluster-worker'
    if sha(binary) != receipt['binarySHA256'] or binary.stat().st_size != receipt['binaryBytes']:
        raise RuntimeError('Built executable changed')
    names = ['darkbloom-cluster-worker', 'mlx.metallib', 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']
    old_resources = {x['path']: x for x in json.loads((OLD / 'runtime-bundle-1/bundle.json').read_bytes())['files']}
    bundle = BASE / ('runtime-bundle-' + attempt)
    bundle.mkdir(mode=0o700)
    rows = []
    for name in names:
        source = directory / name
        if source.is_symlink() or not source.is_file():
            raise RuntimeError('Bundle input is not a regular file')
        if name != 'darkbloom-cluster-worker':
            old = old_resources[name]
            if source.stat().st_size != old['bytes'] or sha(source) != old['sha256']:
                raise RuntimeError('Matched native resource changed')
        destination = bundle / name
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with destination.open('xb') as target, source.open('rb') as origin:
            shutil.copyfileobj(origin, target, length=1024 * 1024)
        destination.chmod(0o700 if name == 'darkbloom-cluster-worker' else 0o600)
        if sha(destination) != sha(source):
            raise RuntimeError('Native bundle copy changed')
        rows.append(dict(path=name, bytes=destination.stat().st_size, sha256=sha(destination)))
    manifest = dict(schema='qwen27b_lookahead_native_bundle_v1', files=rows,
        sourceSnapshotSHA256=sha(BASE / 'source-snapshot-1.json'),
        dependencySnapshotSHA256=sha(BASE / 'dependency-snapshot-1.json'),
        buildReceiptSHA256=sha(run / 'receipt.json'), nativeExecuted=False, remoteExecuted=False)
    (bundle / 'bundle.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(bundle=str(bundle), bundleSHA256=sha(bundle / 'bundle.json'),
                         nativeSHA256=receipt['binarySHA256'])))


if __name__ == '__main__':
    os.umask(0o077)
    main()
