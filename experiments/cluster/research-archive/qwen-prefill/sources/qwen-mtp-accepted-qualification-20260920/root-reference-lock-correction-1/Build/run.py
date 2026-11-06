"""Sequential scheduled builds and metadata-only reference checks; never runs weights."""
import argparse
import json
import os
from pathlib import Path
import time

from inputs import BASE, INPUTS, WORK, SCRATCH, sha, verify_final, write_json
from owned_process import invoke_controller


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output)
    if not output.is_absolute() or output != output.resolve() or output.exists():
        raise ValueError('Output must be fresh and canonical')
    prepared = json.loads((BASE / 'preparation-1/receipt.json').read_bytes())
    if prepared.get('status') != 'passed' or sha(BASE / 'preparation-1/source-after.json') != prepared['sourceAfterSHA256']:
        raise ValueError('Exact preparation has not passed')
    before = verify_final()
    output.mkdir(mode=0o700)
    receipt = dict(schema='qwen_mtp_same_source_build_v1', status='started', before=before,
                   preparationSHA256=sha(BASE / 'preparation-1/receipt.json'),
                   sourceSnapshotSHA256=prepared['sourceAfterSHA256'],
                   dependencySnapshotSHA256=INPUTS['baseDependencies']['sha256'],
                   acceptedManifestSHA256=INPUTS['acceptedManifest']['sha256'], steps=[], products=[],
                   modelExecuted=False, remoteExecuted=False, gpuModeSelected=False)

    def save():
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')

    def run(name, command, timeout):
        row = dict(name=name, argv=command, timeoutSeconds=timeout)
        receipt['steps'].append(row); start = time.monotonic()
        try:
            with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
                invoke_controller(command, stdout, stderr, row, timeout=timeout)
        finally:
            row.update(elapsedSeconds=time.monotonic() - start)
            for stream in ['stdout', 'stderr']:
                path = output / (name + '.' + stream)
                if path.exists():
                    row[stream + 'SHA256'] = sha(path)
                    row[stream + 'Bytes'] = path.stat().st_size
            save()
        if row.get('exitCode') != 0 or not row.get('reaped') or not row.get('groupAbsent') or row.get('failure'):
            raise ValueError('Owned command did not retire successfully: ' + name)

    try:
        for product, package in [('darkbloom-cluster-worker', WORK / 'libs/darkbloom-cluster-worker'),
                                 ('cluster-inference', WORK / 'experiments/cluster/inference')]:
            command = ['swift', 'build', '--package-path', str(package), '--scratch-path', str(SCRATCH),
                       '-c', 'release', '--jobs', '2', '--disable-automatic-resolution', '--skip-update',
                       '--disable-build-manifest-caching', '--triple', 'arm64-apple-macosx26.2',
                       '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2', '--product', product]
            run(product + '-build', command, 900)
            receipt['after_' + product] = verify_final(); save()
            binary = SCRATCH / 'arm64-apple-macosx/release' / product
            run(product + '-version', ['xcrun', 'vtool', '-show-build', str(binary)], 10)
            version = (output / (product + '-version.stdout')).read_text()
            if version.count('LC_BUILD_VERSION') != 1 or 'platform MACOS' not in version or not any(line.split() == ['minos', '26.2'] for line in version.splitlines()):
                raise ValueError('Native deployment target differs')
            receipt['products'].append(dict(product=product, path=str(binary), bytes=binary.stat().st_size, sha256=sha(binary)))
            save()
        binary = SCRATCH / 'arm64-apple-macosx/release/cluster-inference'
        run('reference-controls', ['/usr/bin/env', 'DARKBLOOM_RETAINED_PROFILE_FIXTURE=' + INPUTS['referenceFixture']['path'],
                                   str(binary), '--mode', 'qwen-registered-full-generation-reference-check'], 60)
        expected = dict(accepted=43, actualAllocatorOrLiveResourceAdmissionPerformed=False, cpuOnly=True,
                        kind='qwen_full_generation_reference_entry_check', modelOrNativeForwardExecuted=False, rejected=86)
        if json.loads((output / 'reference-controls.stdout').read_bytes()) != expected:
            raise ValueError('Reference metadata-only controls differ')
        receipt['referenceControls'] = expected
        # A second package root shares this scratch directory. No checkout or
        # Package.resolved changes are accepted implicitly by either build.
        receipt['after'] = verify_final()
        for product in receipt['products']:
            if sha(Path(product['path'])) != product['sha256']:
                raise ValueError('Earlier product changed during the second build')
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt.update(status='failed', failure=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        try:
            receipt['finalSourceCheck'] = verify_final()
        except BaseException as error:
            receipt.update(status='failed', sourceCheckFailure=type(error).__name__ + ': ' + str(error))
        save()
    if receipt['status'] != 'passed':
        raise SystemExit(1)
    print(json.dumps(dict(status=receipt['status'], receiptSHA256=sha(output / 'receipt.json'), products=receipt['products']), sort_keys=True))


if __name__ == '__main__':
    main()
