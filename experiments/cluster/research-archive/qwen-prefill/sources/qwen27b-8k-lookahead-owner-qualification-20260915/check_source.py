"""Check the closed lookahead binding and exact operational inverses; no remote actions."""
import argparse
import ast
import base64
import copy
import json
from pathlib import Path
import sys
from assemble import BASE, pin


def load(path):
    return json.loads(path.read_bytes())


def verify_manifest(row):
    path = Path(row['path'])
    assert pin(path)['sha256'] == row['sha256']
    value = load(path)['files']
    rows = [dict(path=name, **item) for name, item in value.items()] if type(value) is dict else value
    for item in rows:
        actual = pin(path.parent / item['path'])
        assert (actual['bytes'], actual['sha256']) == (item['bytes'], item['sha256'])


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--artifacts', action='store_true')
    args = parser.parse_args()
    lineage = load(BASE / 'lineage.json')
    old = Path(lineage['previousParent']['path']).parent
    verify_manifest(lineage['previousParent'])
    verify_manifest(lineage['comparator'])
    prior, remote = lineage['oldRemoteRoot'], lineage['newRemoteRoot']
    old_native = load(old / 'lineage.json')['nativeBinarySHA256']
    native = lineage['nativeBinarySHA256']
    shared = Path(lineage['sharedInputs']['path'])
    assert pin(shared) == lineage['sharedInputs']
    guard = load(shared)
    assert guard['referenceValidated'] is True
    assert guard['referenceSHA256'] == '1922793ab2f252d52b3729efd4222220935bd1d046c6649fc71afded1ad70305'
    assert load(BASE / 'inputs/expected-token-ids.json') == guard['expectedTokenIDs']
    assert pin(BASE / 'inputs/expected-token-ids.json')['sha256'] == guard['expectedFileSHA256']
    for name in lineage['unchangedFiles']:
        assert (BASE / name).read_bytes() == (old / name).read_bytes(), name
    for name in ('run_physical.py', 'preparation/remote_preflight.py', 'install_new_tree.py'):
        assert (BASE / name).read_text().replace(remote, prior) == (old / name).read_text(), name
    for name in ('inputs/request.json', 'inputs/prompt.ids.json', 'provenance/expected-identity.json', 'configuration/matrix.json'):
        assert (BASE / name).read_bytes() == (old / name).read_bytes(), name

    def restore_ready(encoded):
        raw = base64.b64decode(encoded, validate=True)
        assert raw.count(b'\n') == 1 and raw.endswith(b'\n')
        event = json.loads(raw)
        assert event['ready']['requestCapacityBytes'] == 1
        for peer in event['ready']['identity']['peers']:
            assert peer['buildSHA256'] == native
            peer['buildSHA256'] = old_native
        return event

    for name in ('controller.json', 'owner-rank0.json', 'owner-rank1.json'):
        raw = (BASE / 'configuration' / name).read_bytes()
        assert raw.count(b'\n') == 1 and raw.endswith(b'\n')
        current, previous = json.loads(raw), load(old / 'configuration' / name)
        assert restore_ready(current.pop('readyTemplateBase64')) == json.loads(base64.b64decode(previous.pop('readyTemplateBase64')))
        if name == 'controller.json':
            assert current['membershipEpoch'] == lineage['newEpoch'] != previous['membershipEpoch']
            assert current['expectedTokenIDs'] == guard['expectedTokenIDs']
            current['membershipEpoch'] = previous['membershipEpoch']
            current['expectedTokenIDs'] = None
            for peer in current['peers']:
                peer['installedOwner'] = peer['installedOwner'].replace(remote, prior)
        else:
            assert current['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'] == 'one_chunk_lookahead_v1'
            current['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'] = 'serial_v1'
            current['workerExecutable'] = current['workerExecutable'].replace(remote, prior)
            current['workerEnvironment'] = {k:v.replace(remote, prior) for k,v in current['workerEnvironment'].items()}
        assert current == previous, name
    metadata, previous = load(BASE / 'provenance/recording-metadata.json'), load(old / 'provenance/recording-metadata.json')
    restored = copy.deepcopy(metadata)
    assert restored['nativeBinarySHA256'] == native
    restored['nativeBinarySHA256'] = old_native
    assert [restore_ready(x) for x in restored.pop('readyTemplatesBase64')] == [json.loads(base64.b64decode(x)) for x in previous.pop('readyTemplatesBase64')]
    assert restored == previous
    sys.path.insert(0, str(BASE / 'comparison'))
    from audit_scope import pinned_scope
    from audit_common import request_context, agreement
    request = load(BASE / 'inputs/request.json')
    scope = pinned_scope(request, metadata)
    assert (scope.model_id, scope.cut, scope.prompt, scope.chunk, scope.output, scope.frames, scope.frontier) == ('registered_qwen38_27b', 16, 8192, 512, 128, 143, 8319)
    context = request_context((BASE / 'inputs/prompt.ids.json').read_bytes(), request['requestID'], scope)
    expected = load(BASE / 'expected-agreement.json')
    agreement(expected, context)
    assert expected['membershipEpoch'] == lineage['newEpoch'] and expected['rankBuildSHA256'] == [native, native]
    assert expected['storageCommitmentSHA256'] == '092458153610edef1a62703fc87364fce6aad11b4c064c03d521e8745d19be64'
    assert expected['numericalPolicySHA256'] == '0ae9c7c21048fa94fc90353b84cd8578f4adc05b1b22c3d55bd70f01c9c3bc74'
    for key in ('buildReceipt', 'bundle'):
        assert pin(Path(lineage[key]['path']))['sha256'] == lineage[key]['sha256']
    bundle = {r['path']:r for r in load(Path(lineage['bundle']['path']))['files']}
    deployment, old_deployment = load(BASE / 'deployment.json'), load(old / 'deployment.json')
    for key in ('localController', 'localControlBundle', 'diagnosticOwnerBundle'):
        assert deployment[key] == old_deployment[key]
    unique = {}
    for rank, entry in enumerate(deployment['ranks']):
        assert entry['remoteRoot'] == remote and len(entry['files']) == 14
        previous = {r['path']:r for r in old_deployment['ranks'][rank]['files']}
        for row in entry['files']:
            if row['path'] in bundle:
                actual = bundle[row['path']]
                assert (row['bytes'], row['sha256']) == (actual['bytes'], actual['sha256'])
            elif row['path'] == 'owner.json':
                actual = pin(BASE / 'configuration' / ('owner-rank' + str(rank) + '.json'))
                assert (row['bytes'], row['sha256']) == (actual['bytes'], actual['sha256'])
            else:
                assert (row['bytes'], row['sha256']) == (previous[row['path']]['bytes'], previous[row['path']]['sha256'])
            unique[row['source']] = row
        raw = (BASE / ('deployment-rank' + str(rank) + '.json')).read_bytes()
        assert raw.count(b'\n') == 1 and raw.endswith(b'\n')
        assert json.loads(raw) == dict(schema='qwen27b_load_operands_copy_only_tree_v1', files={'owner/'+r['path']:dict(source=r['source'], bytes=r['bytes'], sha256=r['sha256'], mode=int(r['mode'],8)) for r in entry['files']})
    if args.artifacts:
        for filename, row in unique.items():
            actual = pin(Path(filename))
            assert (actual['bytes'], actual['sha256']) == (row['bytes'], row['sha256'])
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), feature_version=(3, 9))
    assert not any((BASE / name).exists() for name in ('copy-rank0-1', 'copy-rank1-1', 'preflight-1', 'physical-1'))
    print(json.dumps(dict(passed=True, unchangedRuntimeFiles=len(lineage['unchangedFiles']), rootOnlyInverses=3,
        configsAndMetadataOnlyExpectedChanges=True, explicitLookaheadAgreement=True, rankDeploymentFiles=[14,14],
        externalArtifactsRehashed=len(unique) if args.artifacts else 0, compilerNativeModelOrRemoteExecuted=False)))


if __name__ == '__main__':
    main()
