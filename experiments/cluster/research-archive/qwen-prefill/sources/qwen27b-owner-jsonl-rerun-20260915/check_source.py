"""Verify the JSONL-only correction and fresh epoch before physical execution."""
from pathlib import Path
import ast
import base64
import hashlib
import json

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen27b-owner-physical-parent-draft-20260915'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return h.hexdigest()

def verify():
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    assert digest(OLD / 'manifest.json') == lineage['parentManifestSHA256']
    for entry in json.loads((OLD / 'manifest.json').read_bytes())['files']:
        path = OLD / entry['path']
        assert path.stat().st_size == entry['bytes'] and digest(path) == entry['sha256']
    old_pins = json.loads((OLD / 'run-pins.json').read_bytes())['files']
    changed = {'configuration/controller.json', 'configuration/owner-rank0.json',
               'configuration/owner-rank1.json', 'deployment.json', 'expected-agreement.json',
               'comparison-gates.json', 'provenance/expected-agreement-prepare-receipt.json'}
    unchanged = 0
    for entry in old_pins:
        source = Path(entry['path'])
        if source.is_relative_to(OLD):
            relative = source.relative_to(OLD)
            if str(relative) not in changed:
                assert (BASE / relative).read_bytes() == source.read_bytes(), relative
                unchanged += 1
    for change in lineage['configurationChanges']:
        before_path, after_path = OLD / change['file'], BASE / change['file']
        assert digest(before_path) == change['beforeSHA256']
        assert digest(after_path) == change['afterSHA256']
        raw = after_path.read_bytes()
        assert raw.endswith(b'\n') and raw.count(b'\n') == 1
        before, after = json.loads(before_path.read_bytes()), json.loads(raw)
        for key, values in change['objectChanges'].items():
            assert before[key] == values['before'] and after[key] == values['after']
            before[key] = values['after']
        assert before == after
        template = base64.b64decode(after['readyTemplateBase64'], validate=True)
        assert template.endswith(b'\n') and template.count(b'\n') == 1
    old_expected = json.loads((OLD / 'expected-agreement.json').read_bytes())
    expected = json.loads((BASE / 'expected-agreement.json').read_bytes())
    old_expected['membershipEpoch'] = lineage['newEpoch']
    assert old_expected == expected
    controller = json.loads((BASE / 'configuration/controller.json').read_bytes())
    assert controller['membershipEpoch'] == expected['membershipEpoch']
    assert controller['requestID'] == expected['requestID']
    for rank in (0, 1):
        owner = json.loads((BASE / f'configuration/owner-rank{rank}.json').read_bytes())
        assert owner['clusterID'] == controller['clusterID']
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), feature_version=(3, 9))
    for entry in json.loads((BASE / 'run-pins.json').read_bytes())['files']:
        path = Path(entry['path'])
        assert path.stat().st_size == entry['bytes'] and digest(path) == entry['sha256'], path
    for rank in json.loads((BASE / 'deployment.json').read_bytes())['ranks']:
        for entry in rank['files']:
            path = Path(entry['source'])
            assert path.stat().st_size == entry['bytes'] and digest(path) == entry['sha256']
    return {'passed': True, 'runtimeAndHelpersUnchanged': True, 'unchangedPinnedLocalInputs': unchanged,
            'configurationCorrection': 'compact outer JSONL plus fresh clusterID/membershipEpoch',
            'readyTemplatesUnchanged': True, 'agreementOnlyEpochChanged': True,
            'compilerModelOrNetworkExecuted': False}

if __name__ == '__main__':
    print(json.dumps(verify(), indent=2))
