"""Package only a tested native worker and its actual metadata descriptions."""
import json
import os
import re
import shutil
import sys
from retry_inputs import BASE, SCRATCH, inputs, sha
from check_results import require_tests
from run_checks import PRODUCT
from validate_description import validate
from verify_retry import verify


def main():
    if len(sys.argv) != 6 or any(not re.fullmatch(r'[A-Za-z0-9_-]+', x) for x in sys.argv[1:]):
        raise ValueError('Expected runtime/worker/capability/native attempts and fresh bundle name')
    value, old, _, _, _ = inputs()
    verify()
    attempts = dict(zip(('runtime', 'worker', 'capability', 'native'), sys.argv[1:5]))
    records, pins = {}, {}
    for phase, name in attempts.items():
        directory = BASE / name
        record = json.loads((directory / 'receipt.json').read_bytes())
        if record.get('status') != 'passed' or record.get('phase') != phase:
            raise ValueError('A required actual phase did not pass')
        if record.get('sourceManifestSHA256') != value['candidateManifestSHA256']:
            raise ValueError('Tested source manifest differs')
        for filename, field in [('source-snapshot-2.json', 'sourceSnapshotSHA256'),
                                ('dependency-snapshot-2.json', 'dependencySnapshotSHA256')]:
            if sha(BASE / filename) != record[field]:
                raise ValueError('Tested snapshot differs')
        if not record['steps'] or any(step.get('exitCode') != 0 or not step.get('reaped') or
                                     not step.get('groupAbsent') or step.get('timedOut') for step in record['steps']):
            raise ValueError('Actual command retirement is incomplete')
        if any(record.get(key) is not False for key in ('modelExecuted', 'gpuExecuted', 'remoteExecuted', 'protectedTransportExecuted', 'servingEnabled')):
            raise ValueError('Unexpected execution claim')
        if phase in ('runtime', 'worker'):
            expected = json.loads((BASE / 'expected-tests.json').read_bytes())[phase]
            result = require_tests((directory / 'tests.stdout').read_bytes() + (directory / 'tests.stderr').read_bytes(), expected)
            if result != record['testResults']:
                raise ValueError('Test result record differs from actual output')
        elif phase == 'capability':
            if json.loads((directory / 'input-and-producer.stdout').read_bytes()) != json.loads((BASE / 'expected-capability.json').read_bytes()):
                raise ValueError('Original capability result bytes differ')
            command = json.loads((directory / 'command.stdout').read_bytes())
            if command.get('passed') is not True or command.get('actualCPUChildren') != 5:
                raise ValueError('Original capability command controls missing')
        pins[phase] = dict(attempt=name, receiptSHA256=sha(directory / 'receipt.json'))
        records[phase] = record
    native = records['native']
    run = BASE / attempts['native']
    release = SCRATCH / 'arm64-apple-macosx/release'
    binary = release / PRODUCT
    if str(binary) != native['binary']['path'] or sha(binary) != native['binary']['sha256'] or binary.stat().st_size != native['binary']['bytes']:
        raise ValueError('Actual native worker changed')
    description = validate((run / 'ordinary-description.stdout').read_bytes(),
                           (run / 'protected-description.stdout').read_bytes(),
                           native['binary']['sha256'], BASE / 'description-contract.json')
    if description != native['description']:
        raise ValueError('Native description result changed')
    resources = {r['path']: r for r in json.loads((old / 'runtime-bundle-1/bundle.json').read_bytes())['files']}
    bundle = BASE / sys.argv[5]
    bundle.mkdir(mode=0o700)
    files = []

    def copy(source, name, expected, executable=False):
        if source.is_symlink() or not source.is_file():
            raise ValueError('Bundle input is not a regular file')
        actual = dict(bytes=source.stat().st_size, sha256=sha(source))
        if any(actual[key] != expected[key] for key in ('bytes', 'sha256')):
            raise ValueError('Bundle input bytes differ: ' + name)
        target = bundle / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with source.open('rb') as origin, target.open('xb') as destination:
            shutil.copyfileobj(origin, destination, length=1024 * 1024)
        target.chmod(0o700 if executable else 0o600)
        if sha(target) != actual['sha256'] or target.stat().st_size != actual['bytes']:
            raise ValueError('Bundle copy differs')
        files.append(dict(path=name, **actual))

    copy(binary, PRODUCT, native['binary'], executable=True)
    for name in ('mlx.metallib', 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal'):
        copy(release / name, name, resources[name])
    for name, source_name in [('ordinary-capability.json', 'ordinary-description.stdout'),
                              ('protected-runtime-description.json', 'protected-description.stdout')]:
        source = run / source_name
        copy(source, name, dict(bytes=source.stat().st_size, sha256=sha(source)))
    identity = dict(schema='qwen9b_protected_native_source_identity_v1', lineage=value,
                    sourceManifestSHA256=value['candidateManifestSHA256'], wrapperManifestSHA256=sha(BASE / 'manifest.json'),
                    integrationSHA256=sha(BASE / 'integration.json'),
                    sourceSnapshotSHA256=native['sourceSnapshotSHA256'], dependencySnapshotSHA256=native['dependencySnapshotSHA256'],
                    passedPhases=pins, description=description,
                    controls=json.loads((BASE / 'controls.json').read_bytes())['files'],
                    protectedTransportExecuted=False, resourceProfileQualified=False, servingEnabled=False)
    identity_path = bundle / 'source-identity.json'
    with identity_path.open('x') as stream:
        json.dump(identity, stream, indent=2, sort_keys=True)
        stream.write('\n')
    files.append(dict(path=identity_path.name, bytes=identity_path.stat().st_size, sha256=sha(identity_path)))
    verify()
    with (bundle / 'bundle.json').open('x') as stream:
        json.dump(dict(schema='qwen9b_protected_native_bundle_v1', files=files,
                       nativeBinarySHA256=native['binary']['sha256'], description=description,
                       passedPhases=pins, protectedTransportExecuted=False,
                       modelExecuted=False, remoteExecuted=False, servingEnabled=False), stream, indent=2, sort_keys=True)
        stream.write('\n')
    print(json.dumps(dict(bundle=str(bundle), bundleSHA256=sha(bundle / 'bundle.json'),
                          nativeSHA256=native['binary']['sha256'], descriptionSHA256=description['descriptorSHA256'])))


if __name__ == '__main__':
    os.umask(0o077)
    main()
