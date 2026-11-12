"""Package only a successful build and its exact inherited resources; never launch it."""
import json
import os
import shutil
import sys
from build_inputs import BASE, OLD, CACHE, digest as sha, verify, verify_preparation


def main():
    attempt, = sys.argv[1:]
    if not attempt.isdecimal() or not 1 <= int(attempt) <= 99:
        raise ValueError('Expected successful numeric build attempt')
    run = BASE / ('build-' + attempt)
    receipt = json.loads((run / 'receipt.json').read_bytes())
    if receipt.get('passed') is not True or len(receipt['steps']) != 3:
        raise RuntimeError('Successful bounded native build is required')
    verify()
    if verify_preparation() != receipt['buildPreparationManifestSHA256']:
        raise RuntimeError('Build preparation changed after build')
    encoding_path = BASE / ('encoding-' + attempt) / 'receipt.json'
    if sha(encoding_path) != receipt['encodingReceiptSHA256'] or json.loads(encoding_path.read_bytes()).get('passed') is not True:
        raise RuntimeError('Exact successful pre-build encoding check changed')
    check_path = BASE / ('check-' + attempt) / 'receipt.json'
    checked = json.loads(check_path.read_bytes())
    if checked.get('passed') is not True or checked.get('binarySHA256') != receipt['binarySHA256']:
        raise RuntimeError('Matching successful CPU checks required')
    directory = CACHE / 'arm64-apple-macosx/release'
    binary = directory / 'cluster-inference'
    if sha(binary) != receipt['binarySHA256'] or binary.stat().st_size != receipt['binaryBytes']:
        raise RuntimeError('Built executable changed')
    names = ['cluster-inference', 'mlx.metallib', 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']
    old_resources = {x['path']: x for x in json.loads((OLD / 'runtime-bundle-1/bundle.json').read_bytes())['files']}
    bundle = BASE / ('runtime-bundle-' + attempt)
    bundle.mkdir(mode=0o700)
    rows = []
    for name in names:
        source = directory / name
        if source.is_symlink() or not source.is_file():
            raise RuntimeError('Bundle input is not a regular file')
        if name != 'cluster-inference':
            old = old_resources[name]
            if source.stat().st_size != old['bytes'] or sha(source) != old['sha256']:
                raise RuntimeError('Matched native resource changed')
        destination = bundle / name
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with destination.open('xb') as target, source.open('rb') as origin:
            shutil.copyfileobj(origin, target, length=1024 * 1024)
        destination.chmod(0o700 if name == 'cluster-inference' else 0o600)
        if sha(destination) != sha(source):
            raise RuntimeError('Native bundle copy changed')
        rows.append(dict(path=name, bytes=destination.stat().st_size, sha256=sha(destination)))
    source_manifest = dict(schema='qwen27b_resident_solo_build_v1',
        baseBuildManifestSHA256='ceabfece99884fc2f453ddc3d83b1e9c7feb5970cbd4646675f8321b7ffdbb6c',
        reportBoundSourceManifestSHA256=sha(BASE / 'source-manifest.json'),
        encodingCheckReceiptSHA256=sha(BASE / ('encoding-' + attempt) / 'receipt.json'),
        sourceSnapshotSHA256=sha(BASE / 'source-snapshot.json'),
        dependencySnapshotSHA256=sha(BASE / 'dependency-source-snapshot.json'),
        buildReceiptSHA256=sha(run / 'receipt.json'), cpuCheckReceiptSHA256=sha(check_path),
        binarySHA256=receipt['binarySHA256'], cpuCheckPassed=True,
        nativeModelExecuted=False, remoteExecuted=False)
    source_path = BASE / ('build-manifest-' + attempt + '.json')
    with source_path.open('x') as target:
        json.dump(source_manifest, target, indent=2, sort_keys=True); target.write('\n')
    # Preserve the existing supervisor's closed bundle envelope.
    manifest = dict(schemaVersion=1,
        scope='Private registered27B resident solo P8192/C512/O128; unchanged configured1...3 measured requests; 512KiB final ledger and128KiB progress bounds; compiled and CPU checked only',
        sourceManifestSHA256=sha(source_path), files=rows)
    (bundle / 'bundle.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(bundle=str(bundle), bundleSHA256=sha(bundle / 'bundle.json'),
                         nativeSHA256=receipt['binarySHA256'])))


if __name__ == '__main__':
    os.umask(0o077)
    main()
