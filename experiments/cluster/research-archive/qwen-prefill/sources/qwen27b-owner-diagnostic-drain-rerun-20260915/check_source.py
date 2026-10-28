"""Local source/config binding only. Does not import or execute remote scripts."""
from pathlib import Path
import ast
import base64
import hashlib
import json

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen27b-owner-native-diagnostic-rerun-v2-20260915'
CONTROL = BASE.parent / 'cluster-owner-diagnostic-drain-draft-20260915'
UNCHANGED = ['parent_cleanup.py', 'parent_settings.py', 'probe_postflight.py', 'lease_source.py',
    'monitor.py', 'reference_resources.py', 'stage_checks/__init__.py', 'stage_checks/common.py',
    'test_parent_cleanup.py', 'inputs/prompt.ids.json', 'inputs/request.json', 'configuration/matrix.json',
    'configuration/owner-rank0.json', 'configuration/owner-rank1.json', 'provenance/recording-metadata.json',
    'preparation/remote_preflight.py']
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()


def verify():
    assert sha(OLD / 'manifest.json') == '68bb635a1b28eefd54df3b49a72da12aabc0302fa6df085651e4f712c4f10e75'
    old_manifest = json.loads((OLD / 'manifest.json').read_bytes())
    for item in old_manifest['files']:
        assert sha(OLD / item['path']) == item['sha256']
    assert sha(CONTROL / 'manifest.json') == 'ebccbc7e4f216af0313c0f1ce36711f06dd570dafe92a136ce1a673ca4536615'
    for item in json.loads((CONTROL / 'manifest.json').read_bytes())['members']:
        assert sha(CONTROL / item['path']) == item['sha256']
    for name in UNCHANGED:
        assert (BASE / name).read_bytes() == (OLD / name).read_bytes(), name
    original = (OLD / 'run_physical.py').read_text()
    restored = (BASE / 'run_physical.py').read_text().replace(
        "CONTROLLER = ROOT / 'cluster-owner-diagnostic-drain-draft-20260915/local-bundle/owner-controller'",
        "CONTROLLER = ROOT / 'owner-retirement-controls-build-20260915/bundle-qwen27b/owner-controller'")
    assert original == restored
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    before = json.loads((OLD / 'configuration/controller.json').read_bytes())
    after = json.loads((BASE / 'configuration/controller.json').read_bytes())
    before['membershipEpoch'] = lineage['newEpoch']
    assert before == after and after['clusterID'] == lineage['clusterID']
    for path in [BASE / 'configuration/controller.json'] + sorted((BASE / 'configuration').glob('owner-rank*.json')):
        raw = path.read_bytes()
        assert raw.endswith(b'\n') and raw.count(b'\n') == 1
        value = json.loads(raw)
        template = base64.b64decode(value['readyTemplateBase64'], validate=True)
        assert template.endswith(b'\n') and template.count(b'\n') == 1
        assert value['clusterID'] == lineage['clusterID']
    agreement = json.loads((BASE / 'expected-agreement.json').read_bytes())
    previous = json.loads((OLD / 'expected-agreement.json').read_bytes())
    previous['membershipEpoch'] = lineage['newEpoch']
    assert previous == agreement and agreement['requestID'] == after['requestID']
    old_deployment = json.loads((OLD / 'deployment.json').read_bytes())
    deployment = json.loads((BASE / 'deployment.json').read_bytes())
    assert deployment['ranks'] == old_deployment['ranks']
    binary = deployment['localController']
    assert binary['path'] == str(CONTROL / 'local-bundle/owner-controller')
    assert binary['sha256'] == sha(Path(binary['path'])) == '862f7a391afd8f490233db793034c1ec8648c52fd908ba39abbefbf46e899d78'
    bundle = json.loads((CONTROL / 'local-bundle/bundle.json').read_bytes())
    for item in bundle['entries']:
        assert sha(CONTROL / 'local-bundle' / item['path']) == item['sha256']
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), feature_version=(3, 9))
    return {'passed': True, 'unchangedSourceInputs': len(UNCHANGED), 'parentInverseExact': True,
            'controllerOnlyEpochChanged': True, 'agreementOnlyEpochChanged': True,
            'bothRemoteDeploymentTreesExact': True, 'newLocalBundleVerified': True,
            'controllerConfigSHA256': sha(BASE / 'configuration/controller.json'),
            'expectedAgreementSHA256': sha(BASE / 'expected-agreement.json'),
            'remoteCompilerOrModelExecuted': False}


if __name__ == '__main__':
    print(json.dumps(verify(), indent=2))
