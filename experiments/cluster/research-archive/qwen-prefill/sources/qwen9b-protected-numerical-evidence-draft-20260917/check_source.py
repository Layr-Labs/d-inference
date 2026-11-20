"""Small source/inverse checks only; never imports a fixture or opens model/output data."""
import ast
import difflib
import hashlib
import json
from pathlib import Path
import re

BASE = Path(__file__).resolve().parent
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def checked(path, digest, size=None):
    path = Path(path)
    assert not path.is_symlink() and path.is_file() and sha(path) == digest, str(path)
    if size is not None: assert path.stat().st_size == size, str(path)

def main():
    integration = json.loads((BASE / 'integration.json').read_bytes())
    patches = []
    for row in integration['files']:
        target = BASE / 'proposed' / row['path']; checked(target, row['proposedSHA256'], row['bytes'])
        original = BASE / 'originals' / row['path']
        if row['preimageSHA256'] is None:
            assert not original.exists(); before = ''
        else:
            checked(original, row['preimageSHA256']); checked(row['preimageSourcePath'], row['preimageSHA256'])
            before = original.read_text()
        patches.extend(difflib.unified_diff(before.splitlines(True), target.read_text().splitlines(True),
            fromfile='a/' + row['path'] if original.exists() else '/dev/null', tofile='b/' + row['path']))
    assert ''.join(patches) == (BASE / 'runtime.patch').read_text()
    borrow = integration['borrowedExactSource']
    checked(borrow['sourcePath'], borrow['sha256']); checked(BASE / 'proposed' / borrow['targetPath'], borrow['sha256'])
    for row in json.loads((BASE / 'lineage.json').read_bytes())['frozenSourceManifests']:
        checked(row['path'], row['sha256'], row['bytes'])
    for row in json.loads((BASE / 'controls.json').read_bytes())['files']:
        checked(row['path'], row['sha256'], row['bytes'])
    for path in BASE.rglob('*.py'): ast.parse(path.read_text())
    policy = (BASE / 'resource-policy.canonical.json').read_bytes()
    assert hashlib.sha256(policy).hexdigest() == 'dc910813838e3d06a7fcdc1a93ee3b2e8529247839048bff84f50353fb052db5'
    value = json.loads(policy)
    assert json.dumps(value, sort_keys=True, separators=(',', ':')).encode() == policy
    assert value == json.loads((BASE / 'description-contract.json').read_bytes())['resourcePolicy']
    records = (BASE / 'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenProtectedDescriptionRecords.swift').read_text()
    fields = re.findall(r'let (\w+):', records.split('struct QwenProtectedRuntimeDescriptionRecord:')[0])
    assert len(fields) == 33 and set(fields) == set(value)
    expected = json.loads((BASE / 'expected-tests.json').read_bytes())
    assert (len(expected['runtime']['xctest']), len(expected['runtime']['swiftTesting']),
            len(expected['worker']['xctest']), len(expected['provider']['swiftTesting']),
            len(expected['comparison']['methods'])) == (38, 7, 19, 7, 4)
    result = dict(status='passed', proposedSwift=len(integration['files']),
        replacements=sum(r['preimageSHA256'] is not None for r in integration['files']),
        newSwift=sum(r['preimageSHA256'] is None for r in integration['files']),
        exactBorrowedSink=True, exactPatchInverse=True, policyFields=33, descriptorFields=26,
        policySHA256=hashlib.sha256(policy).hexdigest(), compilerExecuted=False,
        fixtureExecuted=False, actualReferenceRead=False, modelOrRemoteExecuted=False)
    print(json.dumps(result, sort_keys=True))

if __name__ == '__main__': main()
