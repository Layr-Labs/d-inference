"""Scheduled create-only three-file native package; no execution mode or secret."""
import json
from pathlib import Path

from commands import run
from guards import BASE, PRODUCT, check, fresh, inventory_check, pin, save_receipt, sha


def main():
    build_path = BASE / 'build-1/receipt.json'
    build = json.loads(build_path.read_bytes())
    if build['schema'] != 'lab_rdma_native_build_v1' or build['status'] != 'passed' or build['product'] != PRODUCT or build['exitCode'] != 0 or not build['compilerReaped'] or build['gpuExecuted']:
        raise ValueError('Actual successful native build is required')
    inventory_check(True)
    metadata = build['nativeMetadataReceipt']
    if sha(Path(metadata['path'])) != metadata['sha256'] or not json.loads(Path(metadata['path']).read_bytes())['passed']:
        raise ValueError('Actual CPU metadata receipt differs')
    pairs = [(PRODUCT, Path(build['nativePath']), dict(bytes=build['nativeBytes'], sha256=build['nativeSHA256']))]
    for row in build['resources']:
        name = 'mlx.metallib' if Path(row['path']).name == 'mlx.metallib' else 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal'
        pairs.append((name, Path(row['path']), dict(bytes=row['bytes'], sha256=row['sha256'])))
    if len(pairs) != 3 or len({x[0] for x in pairs}) != 3:
        raise ValueError('Exact three-file package required')
    for _, source, expected in pairs:
        if pin(source) != expected:
            raise ValueError('Actual package input differs')
    output = BASE / 'native-bundle-1'; fresh(output)
    receipt = dict(schema='lab_rdma_native_bundle_v1', status='started', files=[],
                   buildReceipt=dict(path=str(build_path), sha256=sha(build_path)),
                   sourceReceipt=build['sourceReceipt'], dependencyReceipt=build['dependencyReceipt'],
                   nativeMetadataReceipt=metadata, gpuExecuted=False, remoteExecuted=False)
    try:
        for name, source, expected in pairs:
            target = output / name; target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() or target.is_symlink():
                raise ValueError('Package target already exists')
            run(output, receipt, 'copy-' + source.name, ['/bin/cp', '-c', str(source), str(target)], 30)
            if pin(source) != expected or pin(target) != expected:
                raise ValueError('Cloned package bytes differ')
            receipt['files'].append(dict(path=name, **expected))
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt.update(status='failed', failure=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        save_receipt(output / 'receipt.json', receipt)
    print(json.dumps(dict(receiptSHA256=sha(output / 'receipt.json'), files=receipt['files']), sort_keys=True))


if __name__ == '__main__':
    main()
