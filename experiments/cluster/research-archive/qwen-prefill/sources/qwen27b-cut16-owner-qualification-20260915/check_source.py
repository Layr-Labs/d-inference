"""Prospective source/config checks; full artifact rehash is an explicit separate option."""
import argparse
import ast
import base64
import copy
import json
from pathlib import Path
from assemble import BASE, pin


def load(path):
    return json.loads(path.read_bytes())


def ready(encoded):
    raw = base64.b64decode(encoded, validate=True)
    assert raw.endswith(b'\n') and raw.count(b'\n') == 1
    return json.loads(raw)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--artifacts', action='store_true')
    args = parser.parse_args()
    lineage = load(BASE / 'lineage.json')
    old = Path(lineage['previousParent']['path']).parent
    previous, remote = lineage['oldRemoteRoot'], lineage['newRemoteRoot']
    assert pin(old / 'manifest.json') == lineage['previousParent']
    for row in load(old / 'manifest.json')['files'].items():
        name, expected = row
        value = pin(old / name)
        assert (value['bytes'], value['sha256']) == (expected['bytes'], expected['sha256'])
    for name in lineage['unchangedFiles']:
        assert (BASE / name).read_bytes() == (old / name).read_bytes(), name
    for name in ['run_physical.py', 'preparation/remote_preflight.py', 'install_new_tree.py']:
        assert (BASE / name).read_text().replace(remote, previous) == (old / name).read_text()
    metadata = load(BASE / 'provenance/recording-metadata.json')
    assert pin(BASE / 'provenance/recording-metadata.json')['sha256'] == lineage['actualPureMetadata']['sha256']
    assert metadata['stageCut'] == 16 and metadata['canonicalCounts'] == [463, 1384]
    for name in ['controller.json', 'owner-rank0.json', 'owner-rank1.json']:
        raw = (BASE / 'configuration' / name).read_bytes()
        assert raw.endswith(b'\n') and raw.count(b'\n') == 1
        current, prior = json.loads(raw), load(old / 'configuration' / name)
        rank = 0 if name == 'controller.json' else int(name[-6])
        assert current['readyTemplateBase64'] == metadata['readyTemplatesBase64'][rank]
        event = ready(current['readyTemplateBase64'])
        assert event['ready']['rank'] == rank and event['ready']['requestCapacityBytes'] == 1
        assert all(p['buildSHA256'] == lineage['nativeBinarySHA256'] for p in event['ready']['identity']['peers'])
        current['readyTemplateBase64'] = prior['readyTemplateBase64']
        if name == 'controller.json':
            assert current['membershipEpoch'] == lineage['newEpoch'] != prior['membershipEpoch']
            current['membershipEpoch'] = prior['membershipEpoch']
            for peer in current['peers']:
                peer['installedOwner'] = peer['installedOwner'].replace(remote, previous)
        else:
            assert current['stageCut'] == 16
            current['stageCut'] = 32
            current['workerExecutable'] = current['workerExecutable'].replace(remote, previous)
            current['workerEnvironment'] = {k: v.replace(remote, previous) for k, v in current['workerEnvironment'].items()}
        assert current == prior, name
    request = load(BASE / 'inputs/request.json')
    assert request == dict(load(old / 'inputs/request.json'), stageCut=16)
    assert (BASE / 'inputs/prompt.ids.json').read_bytes() == (old / 'inputs/prompt.ids.json').read_bytes()
    assert (BASE / 'configuration/matrix.json').read_bytes() == (old / 'configuration/matrix.json').read_bytes()
    identity = load(BASE / 'provenance/expected-identity.json')
    agreement, prior = load(BASE / 'expected-agreement.json'), load(old / 'expected-agreement.json')
    assert agreement == dict(prior, membershipEpoch=lineage['newEpoch'],
        planFingerprint=metadata['planSHA256'], stageFingerprints=metadata['stagePlanSHA256'],
        storageCommitmentSHA256=identity['storageCommitmentSHA256'])
    receipt = load(BASE / 'provenance/expected-agreement-prepare-receipt.json')
    assert receipt['exitCode'] == 0 and receipt['expectedAgreement'] == pin(BASE / 'expected-agreement.json')
    assert not (BASE / 'provenance/preparer.stderr').read_bytes()
    deployment, old_deployment = load(BASE / 'deployment.json'), load(old / 'deployment.json')
    assert deployment['localController'] == old_deployment['localController']
    assert deployment['localControlBundle'] == old_deployment['localControlBundle']
    unique = {}
    for rank in [0, 1]:
        rows = deployment['ranks'][rank]
        assert rows['remoteRoot'] == remote and len(rows['files']) == 14
        plan = load(BASE / ('deployment-rank' + str(rank) + '.json'))
        assert plan['files'] == {'owner/' + x['path']: dict(source=x['source'], bytes=x['bytes'], sha256=x['sha256'], mode=int(x['mode'], 8)) for x in rows['files']}
        old_files = {x['path']: x for x in old_deployment['ranks'][rank]['files']}
        for row in rows['files']:
            if row['path'] not in ['owner.json', 'darkbloom-owner-qualification']:
                assert row['sha256'] == old_files[row['path']]['sha256']
            if row['path'] == 'darkbloom-owner-qualification':
                assert row['sha256'] == lineage['ownerSHA256']
            if row['path'] == 'owner.json':
                assert row['sha256'] == pin(BASE / ('configuration/owner-rank' + str(rank) + '.json'))['sha256']
            unique[row['source']] = row
    if args.artifacts:
        for filename, row in unique.items():
            actual = pin(Path(filename))
            assert (actual['bytes'], actual['sha256']) == (row['bytes'], row['sha256'])
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), feature_version=(3, 9))
    assert not any((BASE / name).exists() for name in ['copy-rank0-1', 'copy-rank1-1', 'preflight-1', 'physical-1'])
    print(json.dumps(dict(passed=True, unchangedFiles=len(lineage['unchangedFiles']), rootOnlyInverses=3,
        compactConfigs=3, requestOnlyCutChanges=True, expectedAgreementPrepared=True,
        rankDeploymentFiles=[14, 14], externalArtifactSourcesVerified=len(unique) if args.artifacts else 0,
        compilerNativeModelOrRemoteExecuted=False), indent=2))


if __name__ == '__main__':
    main()
