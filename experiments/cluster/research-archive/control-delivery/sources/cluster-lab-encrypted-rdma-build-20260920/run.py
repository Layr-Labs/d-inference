"""One scheduled native build, deployment check and public CPU metadata controls."""
import json

from commands import run
from guards import BASE, INPUTS, PRODUCT, RELEASE, SCRATCH, WORK, check, fresh, inventory_check, pin, resource_rows, save_receipt, sha
from metadata import qualify


def main():
    preparation = BASE / 'preparation-1/receipt.json'
    prepared = json.loads(preparation.read_bytes())
    if prepared['schema'] != 'lab_rdma_preparation_v1' or prepared['status'] != 'passed' or prepared['sourceManifestSHA256'] != INPUTS['authorities']['nativeManifest']['sha256']:
        raise ValueError('Successful exact preparation required')
    inventory_check(True)
    old = RELEASE / 'darkbloom-cluster-worker'
    if pin(old) != {key: INPUTS['priorBinary'][key] for key in ('bytes', 'sha256')}:
        raise ValueError('Preserved predecessor product changed')
    if (RELEASE / PRODUCT).exists() or (RELEASE / PRODUCT).is_symlink():
        raise ValueError('Lab output already exists; retain prior attempts')
    resources = resource_rows()
    for row in resources:
        check(row)
    output = BASE / 'build-1'; fresh(output)
    receipt = dict(schema='lab_rdma_native_build_v1', status='started', product=PRODUCT,
                   exitCode=None, compilerReaped=False, gpuExecuted=False, modelExecuted=False,
                   remoteExecuted=False, servingEnabled=False,
                   preparationSHA256=sha(preparation),
                   nativeManifestSHA256=INPUTS['authorities']['nativeManifest']['sha256'], resources=resources)
    binary = RELEASE / PRODUCT
    try:
        receipt['before'] = inventory_check(True, output)
        receipt['sourceReceipt'] = dict(path=str(output / 'sources.json'), sha256=sha(output / 'sources.json'))
        receipt['dependencyReceipt'] = dict(path=str(output / 'dependencies.json'), sha256=sha(output / 'dependencies.json'))
        receipt['sourcesSHA256'] = receipt['sourceReceipt']['sha256']
        command = ['/usr/bin/env', 'TMPDIR=/private/tmp/', 'swift', 'build', '--package-path', str(WORK / 'libs/darkbloom-cluster-worker'),
                   '--scratch-path', str(SCRATCH), '-c', 'release', '--jobs', '2', '--disable-automatic-resolution',
                   '--skip-update', '--disable-build-manifest-caching', '--product', PRODUCT,
                   '--triple', 'arm64-apple-macosx26.2', '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2']
        compiled = run(output, receipt, 'compile', command, 900)
        receipt['compilerReaped'] = compiled['reaped'] and compiled['groupAbsent']
        receipt['afterCompile'] = inventory_check(True)
        actual = pin(binary)
        receipt.update(nativePath=str(binary), nativeSHA256=actual['sha256'], nativeBytes=actual['bytes'])
        run(output, receipt, 'deployment', ['xcrun', 'vtool', '-show-build', str(binary)], 15)
        lines = [line.split() for line in (output / 'deployment.stdout').read_text().splitlines()]
        minima = [line for line in lines if line and line[0] == 'minos']
        if lines.count(['cmd', 'LC_BUILD_VERSION']) != 1 or lines.count(['platform', 'MACOS']) != 1 or minima not in ([['minos', '26.2']], [['minos', '26.2.0']]):
            raise ValueError('Actual binary must target exactly macOS26.2')
        run(output, receipt, 'native-backend', ['nm', '-a', str(binary)], 15)
        if 'JACCLGroup' not in (output / 'native-backend.stdout').read_text():
            raise ValueError('Actual binary lacks native JACCL implementation')
        receipt['nativeMetadataReceipt'] = qualify(binary, output / 'metadata')
        if pin(binary) != actual or pin(old) != {key: INPUTS['priorBinary'][key] for key in ('bytes', 'sha256')}:
            raise ValueError('Native or retained predecessor changed')
        for row in resources:
            check(row)
        receipt['status'] = 'passed'; receipt['exitCode'] = 0
    except BaseException as error:
        receipt.update(status='failed', exitCode=1, failure=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        try:
            receipt['after'] = inventory_check(True)
        except BaseException as error:
            receipt.update(status='failed', exitCode=1, finalInventoryFailure=type(error).__name__ + ': ' + str(error))
        save_receipt(output / 'receipt.json', receipt)
    if receipt['status'] != 'passed':
        raise SystemExit(1)
    print(json.dumps(dict(receiptSHA256=sha(output / 'receipt.json'), nativeSHA256=receipt['nativeSHA256'],
                          sourceReceipt=receipt['sourceReceipt'], dependencyReceipt=receipt['dependencyReceipt'],
                          nativeMetadataReceipt=receipt['nativeMetadataReceipt']), sort_keys=True))


if __name__ == '__main__':
    main()
