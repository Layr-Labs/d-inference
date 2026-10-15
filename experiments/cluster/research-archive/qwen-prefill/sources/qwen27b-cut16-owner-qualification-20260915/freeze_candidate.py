"""Freeze this local proposal and external artifact pins after physical timing is released."""
import json
from pathlib import Path
from assemble import BASE, pin


def write(name, value):
    with (BASE / name).open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def main():
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    old = Path(lineage['previousParent']['path']).parent
    audit = Path(lineage['comparator']['path']).parent
    request = json.loads((BASE / 'inputs/request.json').read_bytes())
    meta = json.loads((BASE / 'provenance/recording-metadata.json').read_bytes())
    identity = json.loads((BASE / 'provenance/expected-identity.json').read_bytes())
    reference = BASE.parent / 'qwen27b-cut16-full-reference-20260915/physical-collect-1/returned/native/worker-0.stdout'
    assert pin(reference)['sha256'] == '539f0ed31bf4b95590d26df3468b2d3863520bc742d2c62cd37bcb8ca94d6e26'
    provenance = json.loads((old / 'configuration/input-provenance.json').read_bytes())
    provenance.update(stageCut=16, membershipEpoch=lineage['newEpoch'],
        metadataSHA256=pin(BASE / 'provenance/recording-metadata.json')['sha256'],
        requestFileSHA256=pin(BASE / 'inputs/request.json')['sha256'])
    write('configuration/input-provenance.json', provenance)
    write('comparison-gates.json', dict(comparator=lineage['comparator'],
        expectedAgreement=pin(BASE / 'expected-agreement.json'), registeredRequest=pin(BASE / 'inputs/request.json'),
        registeredPlan=pin(BASE / 'provenance/recording-metadata.json'), prompt=pin(BASE / 'inputs/prompt.ids.json'),
        expectedStorageCommitmentSHA256=identity['storageCommitmentSHA256'],
        expectedNumericalPolicySHA256=identity['arithmeticSHA256'], reference=pin(reference),
        referenceOnlyValidation=pin(BASE / 'reference-only-check.json'), candidateOutputsRead=False,
        candidateNumericalComparisonPerformed=False, physicalCleanupAttested=False))
    reference_command = ['/usr/bin/python3', '-B', str(BASE / 'verify_reference.py'), '--reference', str(reference),
        '--reference-sha256', pin(reference)['sha256'], '--output', str(BASE / 'reference-only-recheck.json')]
    write('commands.json', dict(workingDirectory=str(BASE), executionOwner='root only',
        sourceCheck=['/usr/bin/python3', '-B', str(BASE / 'check_source.py'), '--artifacts'],
        sequentialCopy=[['/usr/bin/python3', '-B', str(BASE / 'deploy_copy_only.py'), '--rank', str(x)] for x in [0, 1]],
        afterAuthorizedPurgeSequentialPreflight=[['/usr/bin/python3', '-B', str(BASE / 'preflight.py'), '--rank', str(x)] for x in [0, 1]],
        physical=['/usr/bin/python3', '-B', str(BASE / 'run_physical.py')], referenceOnlyValidation=reference_command,
        comparisonTemplate=['/usr/bin/python3', '-B', str(audit / 'audit_generation.py'), '--packet', 'NEW_PACKET_PATH',
            '--packet-sha256', 'DECLARED_PACKET_SHA256', '--output', 'NEW_COMPARISON_OUTPUT_PATH'],
        noAutomaticRetry=True))
    paths = set()
    for row in json.loads((old / 'run-pins.json').read_bytes())['files']:
        path = Path(row['path'])
        if path.is_relative_to(old):
            replacement = BASE / path.relative_to(old)
            if replacement.is_file(): path = replacement
        paths.add(path)
    deployment = json.loads((BASE / 'deployment.json').read_bytes())
    for rank in deployment['ranks']:
        paths.update(Path(x['source']) for x in rank['files'])
    for field in ['ownerBuild', 'ownerPreparation', 'comparator', 'actualPureMetadata']:
        paths.add(Path(lineage[field]['path']))
    paths.add(Path(lineage['ownerBuild']['path']).parent / 'linkage.json')
    for row in json.loads((audit / 'manifest.json').read_bytes())['files']:
        paths.add(audit / row['path'])
    paths.add(reference)
    paths.update(path for path in BASE.rglob('*') if path.is_file())
    write('run-pins.json', dict(schema='qwen27b_cut16_run_pins_v1', files=[pin(p) for p in sorted(paths)]))
    files = {}
    for path in sorted(BASE.rglob('*')):
        if path.is_file() and path.name != 'manifest.json':
            value = pin(path)
            files[str(path.relative_to(BASE))] = dict(bytes=value['bytes'], sha256=value['sha256'])
    write('manifest.json', dict(schema='qwen27b_cut16_owner_qualification_v1',
        referenceOnlyValidationPerformed=True, candidateOutputsRead=False, remoteActionsExecuted=False, files=files))
    print(json.dumps(dict(manifest=pin(BASE / 'manifest.json'), members=len(files),
                         runPins=pin(BASE / 'run-pins.json'), runPinCount=len(paths))))


if __name__ == '__main__':
    main()
