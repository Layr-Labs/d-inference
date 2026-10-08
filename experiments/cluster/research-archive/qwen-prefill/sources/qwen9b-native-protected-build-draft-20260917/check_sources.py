"""Small source/metadata checks only; never walks a workspace or cache."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    candidate = Path(lineage['candidate'])
    assert sha(candidate / 'manifest.json') == lineage['candidateManifestSHA256']
    for row in json.loads((candidate / 'manifest.json').read_bytes())['files']:
        assert sha(candidate / row['path']) == row['sha256']
    old = Path(lineage['base'])
    for name, digest in lineage['ancestryMetadata'].items():
        assert sha(old / name) == digest
    previous = json.loads((old / 'source-snapshot-1.json').read_bytes())['members']
    effective = {row['path']: row.get('sha256') for row in previous}
    original = dict(effective)
    integration = json.loads((BASE / 'integration.json').read_bytes())
    for row in integration['files']:
        assert original.get(row['path']) == row['beforeSHA256']
        assert sha(Path(row['source'])) == row['afterSHA256']
        effective[row['path']] = row['afterSHA256']
    for row in integration['exclude']:
        assert effective.pop(row['path']) == row['beforeSHA256']
    assert len(effective) == lineage['expectedSourceCount'] == 3075
    for row in json.loads((BASE / 'controls.json').read_bytes())['files']:
        assert effective[row['path']] == row['sha256']
    for row in json.loads((BASE / 'helper-lineage.json').read_bytes()):
        assert sha(BASE / row['destination']) == sha(Path(row['source'])) == row['sha256']
    for row in json.loads((BASE / 'fixture-supplement.json').read_bytes()):
        if row.get('byteExact'):
            assert sha(Path(row['source'])) == sha(BASE / 'supplement' / row['path']) == row['sha256']
    for path in BASE.glob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    tests = json.loads((BASE / 'expected-tests.json').read_bytes())
    assert len(tests['runtime']['xctest']) == 34 and len(tests['runtime']['swiftTesting']) == 7
    assert len(tests['worker']['xctest']) == 15 and tests['worker']['swiftTesting'] == []
    schema = json.loads((candidate / 'description-schema.json').read_bytes())
    contract = json.loads((BASE / 'description-contract.json').read_bytes())
    assert contract['schema'] == schema and len(schema['fields']) == 26
    assert contract['resourcePolicy']['additionalHostBytes'] + contract['resourcePolicy']['additionalNativeBytes'] == 186302720
    return dict(sourceOnly=True, sourceManifestSHA256=lineage['candidateManifestSHA256'],
                resultingSources=3075, dependencies=8755, overlays=44, exclusions=7,
                exactCopiedHelpers=6, xctestMethods=49, retainedScopeMethods=7,
                preparationExecuted=False, compilerExecuted=False, testsExecuted=False,
                modelExecuted=False, remoteExecuted=False)


if __name__ == '__main__':
    print(json.dumps(check(), sort_keys=True))
