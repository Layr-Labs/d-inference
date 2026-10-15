"""Freeze local source/evidence closure; never packages or executes remote commands."""
import json
from pathlib import Path
from assemble import BASE, ROOT, OLD, BUILD, pin, write


def main():
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    provenance = json.loads((OLD / 'configuration/input-provenance.json').read_bytes())
    provenance.update(membershipEpoch=lineage['newEpoch'], nativeBinarySHA256=lineage['nativeBinarySHA256'],
                      metadataSHA256=pin(BASE / 'provenance/recording-metadata.json')['sha256'])
    write('configuration/input-provenance.json', provenance)
    trust = json.loads((OLD / 'controller-trust-lineage.json').read_bytes())
    write('provenance/trust-preservation.json', dict(previousTrustLineage=pin(OLD / 'controller-trust-lineage.json'),
        knownHosts=trust['knownHosts'], privateKeyReadOrHashed=False, peerTrustFieldsUnchanged=True,
        remoteAuthenticationExecuted=False))
    commands = dict(workingDirectory=str(BASE), executionOwner='root only',
        sourceCheck=['/usr/bin/python3', '-B', str(BASE / 'check_source.py')],
        sequentialCopy=[['/usr/bin/python3', '-B', str(BASE / 'deploy_copy_only.py'), '--rank', str(x)] for x in [0, 1]],
        afterAuthorizedPurgeSequentialPreflight=[['/usr/bin/python3', '-B', str(BASE / 'preflight.py'), '--rank', str(x)] for x in [0, 1]],
        physical=['/usr/bin/python3', '-B', str(BASE / 'run_physical.py')],
        noAutomaticRetry=True, noNativeLaunchDuringCopy=True,
        existingRemoteTreeMustNotExist=True, journalMustBeEmpty=True)
    write('commands.json', commands)
    paths = set()
    for row in json.loads((OLD / 'run-pins.json').read_bytes())['files']:
        path = Path(row['path'])
        if path.is_relative_to(OLD):
            replacement = BASE / path.relative_to(OLD)
            if replacement.is_file(): path = replacement
        paths.add(path)
    deployment = json.loads((BASE / 'deployment.json').read_bytes())
    for rank in deployment['ranks']:
        paths.update(Path(row['source']) for row in rank['files'])
    for field in ['nativeBuildReceipt', 'nativeBundle', 'sourceSnapshot', 'dependencySnapshot', 'diagnosticOverlay']:
        paths.add(Path(lineage[field]['path']))
    for path in BASE.rglob('*'):
        if path.is_file() and path.name not in ['manifest.json', 'run-pins.json']:
            paths.add(path)
    rows = [pin(path) for path in sorted(paths)]
    write('run-pins.json', dict(schema='qwen27b_load_operand_run_pins_v1', files=rows))
    members = {}
    for path in sorted(BASE.rglob('*')):
        if path.is_file() and path.name != 'manifest.json':
            value = pin(path)
            members[str(path.relative_to(BASE))] = dict(bytes=value['bytes'], sha256=value['sha256'])
    write('manifest.json', dict(schema='qwen27b_owner_load_operand_rerun_v1',
        remoteActionsExecuted=False, nativeOrModelExecuted=False, files=members))
    print(json.dumps(dict(manifest=pin(BASE / 'manifest.json'), members=len(members),
        runPins=pin(BASE / 'run-pins.json'), runPinCount=len(rows))))


if __name__ == '__main__':
    main()
