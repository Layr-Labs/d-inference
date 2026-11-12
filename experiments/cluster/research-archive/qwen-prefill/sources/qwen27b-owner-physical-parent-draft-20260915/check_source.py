"""Read-only local source/config/artifact verification; no helper or model execution."""
from pathlib import Path
import ast
import base64
import hashlib
import json

BASE = Path(__file__).resolve().parent


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def verify():
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    for entry in lineage['exactCleanupAndSupport']:
        assert digest(BASE / entry['destination']) == entry['sha256']
        assert (BASE / entry['destination']).read_bytes() == Path(entry['source']).read_bytes()
    before = ast.parse((BASE / 'originals/run_physical.py').read_text(), feature_version=(3, 9))
    after = ast.parse((BASE / 'run_physical.py').read_text(), feature_version=(3, 9))
    for tree in (before, after):
        for node in tree.body:
            if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
                if node.targets[0].id in ('REMOTE', 'CONTROLLER'):
                    node.value = ast.Constant(value='explicit-bound-path')
    assert ast.dump(before) == ast.dump(after)
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), feature_version=(3, 9))

    original = json.loads((BASE / 'originals/controller.json').read_bytes())
    controller = json.loads((BASE / 'configuration/controller.json').read_bytes())
    trust = json.loads((BASE / 'controller-trust-lineage.json').read_bytes())
    assert len(trust['changedFields']) == 4
    for change in trust['changedFields']:
        _, rank, field = change['path']
        assert original['peers'][rank][field] == change['before']
        assert controller['peers'][rank][field] == change['after']
        original['peers'][rank][field] = change['after']
    assert original == controller
    assert digest(Path(trust['knownHosts']['path'])) == trust['knownHosts']['sha256']

    request = json.loads((BASE / 'inputs/request.json').read_bytes())
    prompt = json.loads((BASE / 'inputs/prompt.ids.json').read_bytes())
    metadata = json.loads((BASE / 'provenance/recording-metadata.json').read_bytes())
    assert len(prompt) == 32 and all(type(token) is int and 0 <= token < 248320 for token in prompt)
    assert request['promptFileSHA256'] == digest(BASE / 'inputs/prompt.ids.json')
    assert request['promptTokenIDsSHA256'] == hashlib.sha256(','.join(map(str, prompt)).encode()).hexdigest()
    assert request['model'] == metadata['modelID'] == 'registered_qwen38_27b'
    assert request['artifactSHA256'] == metadata['artifactSHA256']
    assert request['configurationSHA256'] == metadata['configurationSHA256']
    assert request['manifestSHA256'] == metadata['manifestSHA256']
    assert request['requestID'] == controller['requestID'] == '20801ced-ca29-4faf-b71a-9ebbe1886a14'
    assert request['promptCount'] == 32 and request['chunkSize'] == controller['chunkSize'] == 16
    assert request['outputCount'] == controller['outputCount'] == 128 and request['stageCut'] == 32
    assert request['stopTokenIDs'] == controller['stopTokenIDs'] == [] and request['mtp'] is False
    assert controller['promptTokenIDs'] == prompt and controller['expectedTokenIDs'] is None
    assert controller['membershipEpoch'] == '93604d14-37da-4e80-ad11-9ddf9ff48d1e'
    assert controller['lifetimeSeconds'] == 300 and controller['startupSeconds'] == 90
    assert controller['requestSeconds'] == 120 and controller['cpuQualification'] is False
    assert metadata['stageCut'] == 32 and metadata['canonicalCounts'] == [923, 924]
    assert metadata['activeBytes'] == [7566395904, 7566406144]
    assert metadata['actualReadinessObserved'] is False and metadata['nativeExecuted'] is False
    for rank in (0, 1):
        path = BASE / f'configuration/owner-rank{rank}.json'
        assert path.read_bytes() == (Path(lineage['configurationSource']) / path.name).read_bytes()
        owner = json.loads(path.read_bytes())
        ready = json.loads(base64.b64decode(owner['readyTemplateBase64'], validate=True))['ready']
        assert owner['clusterID'] == controller['clusterID'] and owner['stageCut'] == 32
        assert owner['leaseDirectory'] == '/Users/developer/.darkbloom/cluster-device'
        assert owner['maximumLifetimeSeconds'] == 300
        assert owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'] == 'serial_v1'
        assert ready['rank'] == rank and ready['executionPlanSHA256'] == metadata['planSHA256']
        assert ready['identity']['modelID'] == metadata['modelID'] and ready['requestCapacityBytes'] == 1
        assert all(peer['buildSHA256'] == metadata['nativeBinarySHA256'] for peer in ready['identity']['peers'])
    deployment = json.loads((BASE / 'deployment.json').read_bytes())
    assert deployment['totalFilesPerRank'] == 14 and deployment['runtimeFilesPerRank'] == 8
    observed = set()
    for rank in deployment['ranks']:
        assert len(rank['files']) == len({entry['path'] for entry in rank['files']}) == 14
        for entry in rank['files']:
            source = Path(entry['source'])
            if source not in observed:
                assert source.stat().st_size == entry['bytes'] and digest(source) == entry['sha256']
                observed.add(source)
    pins = json.loads((BASE / 'run-pins.json').read_bytes())['files']
    for entry in pins:
        path = Path(entry['path'])
        assert path.stat().st_size == entry['bytes'] and digest(path) == entry['sha256']
    comparison = json.loads((BASE / 'comparison-gates.json').read_bytes())
    expected = json.loads((BASE / 'expected-agreement.json').read_bytes())
    assert expected['membershipEpoch'] == controller['membershipEpoch']
    assert expected['requestID'] == controller['requestID']
    assert expected['planFingerprint'] == metadata['planSHA256']
    assert expected['stageFingerprints'] == metadata['stagePlanSHA256']
    assert expected['rankBuildSHA256'] == [metadata['nativeBinarySHA256']] * 2
    assert expected['storageCommitmentSHA256'] == comparison['expectedStorageCommitmentSHA256']
    assert expected['numericalPolicySHA256'] == comparison['expectedNumericalPolicySHA256']
    assert expected['mtpEnabled'] is False and comparison['actualComparisonPerformed'] is False
    return dict(schema='qwen27b_parent_source_checks_v1', passed=True,
                exactHelpers=len(lineage['exactCleanupAndSupport']), parentASTOnlyTwoPathChanges=True,
                controllerOnlyFourTrustFieldsChanged=True, ownerConfigurationsUnchanged=True,
                requestAndTemplateBindingsMatch=True, deploymentFilesVerified=len(observed),
                runtimeInputPinsVerified=len(pins), expectedAgreementSourceBindingsVerified=True, python39Syntax=True,
                cleanupTests='Inherited exact thirteen methods; predecessor execution retained, not rerun',
                compilerNativeModelOrNetworkExecuted=False)


if __name__ == '__main__':
    print(json.dumps(verify(), indent=2, sort_keys=True))
