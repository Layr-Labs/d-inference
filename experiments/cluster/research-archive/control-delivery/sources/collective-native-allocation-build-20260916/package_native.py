"""Package the successful new binary and exact inherited resources, without running it."""
import json
import os
import re
import shutil
import sys
from build_inputs import BASE, SCRATCH, inputs, sha
from verify_build_inputs import verify
from build_native import PRODUCT


def main():
    if len(sys.argv) != 3 or any(not re.fullmatch(r'[A-Za-z0-9_-]+', x) for x in sys.argv[1:]):
        raise ValueError('Expected build attempt and fresh bundle directory names')
    attempt, bundle_name = sys.argv[1:]
    run = BASE / attempt
    receipt = json.loads((run / 'receipt.json').read_bytes())
    if (receipt.get('status') != 'passed' or receipt.get('product') != PRODUCT or len(receipt['steps']) != 4 or
            receipt.get('nativeFixtureExecuted') is not False or receipt.get('catalog', {}).get('count') != 35):
        raise ValueError('Successful bounded build and exact pure catalog are required')
    v, old, _, _, _ = inputs()
    verify()
    for name, key in [('source-snapshot-1.json', 'sourceSnapshotSHA256'),
                      ('dependency-snapshot-1.json', 'dependencySnapshotSHA256')]:
        if sha(BASE / name) != receipt[key]:
            raise ValueError('Build snapshot identity changed')
    directory = SCRATCH / 'arm64-apple-macosx/release'
    binary = directory / PRODUCT
    if str(binary) != receipt['binary']['path'] or sha(binary) != receipt['binary']['sha256'] or binary.stat().st_size != receipt['binary']['bytes']:
        raise ValueError('Built executable changed')
    resources = {r['path']: r for r in json.loads((old / 'runtime-bundle-1/bundle.json').read_bytes())['files']}
    bundle = BASE / bundle_name
    bundle.mkdir(mode=0o700)
    files = []
    for name in [PRODUCT, 'mlx.metallib', 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']:
        source = directory / name
        if source.is_symlink() or not source.is_file():
            raise ValueError('Bundle input must be a regular file')
        actual = dict(bytes=source.stat().st_size, sha256=sha(source))
        expected = receipt['binary'] if name == PRODUCT else resources[name]
        if any(actual[k] != expected[k] for k in ('bytes', 'sha256')):
            raise ValueError('Binary or inherited native resource changed: ' + name)
        target = bundle / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with source.open('rb') as origin, target.open('xb') as destination:
            shutil.copyfileobj(origin, destination, length=1024 * 1024)
        target.chmod(0o700 if name == PRODUCT else 0o600)
        if sha(target) != actual['sha256'] or target.stat().st_size != actual['bytes']:
            raise ValueError('Bundle copy differs')
        files.append(dict(path=name, **actual))
    identity = dict(schema='collective_allocation_source_identity_v1', lineage=v,
                    integrationSHA256=sha(BASE / 'integration.json'), runtimePatchSHA256=sha(BASE / 'runtime.patch'),
                    wrapperManifestSHA256=sha(BASE / 'manifest.json'), buildReceiptSHA256=sha(run / 'receipt.json'),
                    sourceSnapshotSHA256=receipt['sourceSnapshotSHA256'],
                    dependencySnapshotSHA256=receipt['dependencySnapshotSHA256'],
                    catalog=receipt['catalog'], controls=json.loads((BASE / 'controls.json').read_bytes())['files'],
                    nativeExecuted=False, resourceProfileQualified=False)
    with (bundle / 'source-identity.json').open('x') as f:
        json.dump(identity, f, indent=2, sort_keys=True)
        f.write('\n')
    (bundle / 'source-identity.json').chmod(0o600)
    files.append(dict(path='source-identity.json', bytes=(bundle / 'source-identity.json').stat().st_size,
                      sha256=sha(bundle / 'source-identity.json')))
    verify()
    with (bundle / 'bundle.json').open('x') as f:
        json.dump(dict(schema='collective_allocation_native_bundle_v1', files=files,
                       buildReceiptSHA256=sha(run / 'receipt.json'), nativeExecuted=False, remoteExecuted=False), f, indent=2)
        f.write('\n')
    print(json.dumps(dict(bundle=str(bundle), bundleSHA256=sha(bundle / 'bundle.json'), nativeSHA256=receipt['binary']['sha256'])))


if __name__ == '__main__':
    os.umask(0o077)
    main()
