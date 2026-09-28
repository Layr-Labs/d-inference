"""Source/config-only prospective binding; installed bytes require remote preflight."""
from pathlib import Path
import ast
import base64
import hashlib
import json

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen27b-owner-jsonl-rerun-20260915'
UNCHANGED = ['run_physical.py', 'parent_cleanup.py', 'parent_settings.py', 'probe_postflight.py',
             'lease_source.py', 'monitor.py', 'reference_resources.py', 'stage_checks/__init__.py',
             'stage_checks/common.py', 'test_parent_cleanup.py', 'inputs/prompt.ids.json', 'inputs/request.json',
             'configuration/owner-rank0.json', 'configuration/owner-rank1.json', 'configuration/matrix.json',
             'provenance/recording-metadata.json']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify():
    assert digest(OLD / 'manifest.json') == '86998a7aaf2444e6e19b4f0f1c15faf11d0ae6385174c3b898b87dcf004ce534'
    old_manifest = json.loads((OLD / 'manifest.json').read_bytes())
    for item in old_manifest['files']:
        assert digest(OLD / item['path']) == item['sha256']
    for name in UNCHANGED:
        assert (BASE / name).read_bytes() == (OLD / name).read_bytes(), name
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    before = json.loads((OLD / 'configuration/controller.json').read_bytes())
    after = json.loads((BASE / 'configuration/controller.json').read_bytes())
    before['membershipEpoch'] = lineage['newEpoch']
    assert before == after and after['clusterID'] == lineage['clusterID']
    for path in [BASE / 'configuration/controller.json'] + sorted((BASE / 'configuration').glob('owner-rank*.json')):
        raw = path.read_bytes()
        assert raw.endswith(b'\n') and raw.count(b'\n') == 1
        value = json.loads(raw)
        assert value['clusterID'] == after['clusterID']
        template = base64.b64decode(value['readyTemplateBase64'], validate=True)
        assert template.endswith(b'\n') and template.count(b'\n') == 1
    prior_agreement = json.loads((OLD / 'expected-agreement.json').read_bytes())
    expected = json.loads((BASE / 'expected-agreement.json').read_bytes())
    prior_agreement['membershipEpoch'] = lineage['newEpoch']
    assert prior_agreement == expected and expected['membershipEpoch'] == after['membershipEpoch']
    assert expected['requestID'] == after['requestID']
    old_deployment = json.loads((OLD / 'deployment.json').read_bytes())
    deployment = json.loads((BASE / 'deployment.json').read_bytes())
    assert deployment['localController'] == old_deployment['localController']
    for old_rank, rank in zip(old_deployment['ranks'], deployment['ranks']):
        assert old_rank['remoteRoot'] == rank['remoteRoot'] and old_rank['host'] == rank['host']
        assert len(rank['files']) == 14
        for old_file, new_file in zip(old_rank['files'], rank['files']):
            assert old_file['path'] == new_file['path']
            if new_file['path'] == 'darkbloom-owner-qualification':
                assert new_file['sha256'] == 'da5542b115279db5f3f6e0794d96cdaa54cff1d193bee8c9d4bb24edc870c8a8'
                continue
            assert {k:v for k,v in old_file.items() if k != 'source'} == {k:v for k,v in new_file.items() if k != 'source'}
    original_preflight = BASE.parent / 'qwen27b-owner-physical-parent-draft-20260915/preflight-1/remote-preflight.py'
    assert (BASE / 'preparation/remote_preflight.py').read_bytes() == original_preflight.read_bytes()
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), feature_version=(3, 9))
    return {'passed': True, 'upstreamMembersVerified': len(old_manifest['files']),
            'exactUnchangedInputs': len(UNCHANGED), 'controllerOnlyEpochChanged': True,
            'ownerConfigurationsUnchanged': True, 'existingParentRuntimeAndCleanupExact': True,
            'agreementOnlyEpochChanged': True, 'deploymentOnlyOwnerBinaryChanged': True,
            'newEpoch': lineage['newEpoch'], 'controllerSHA256': digest(BASE / 'configuration/controller.json'),
            'expectedAgreementSHA256': digest(BASE / 'expected-agreement.json'),
            'remotePreflightExecuted': False, 'modelCompilerOrNetworkExecuted': False}


if __name__ == '__main__':
    print(json.dumps(verify(), indent=2, sort_keys=True))
