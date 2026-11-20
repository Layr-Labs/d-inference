#!/usr/bin/env python3
"""Read only the explicit small source closure; never build, copy or execute it."""
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    value = json.loads((ROOT / 'lineage.json').read_text())
    base = Path(value['qualifiedWorkspace'])
    assert digest(Path(value['promotionMap']['path'])) == value['promotionMap']['sha256']
    patch = ''
    for row in value['overlay']:
        rel = row['path']
        proposed, original = ROOT / 'proposed' / rel, ROOT / 'original' / rel
        assert digest(proposed) == row['candidateSHA256']
        assert proposed.stat().st_size == row['candidateBytes']
        if row['preimageSHA256'] is None:
            assert not original.exists() and not (base / rel).exists()
            old = ''
        else:
            assert digest(original) == digest(base / rel) == row['preimageSHA256']
            old = original.read_text()
        if row['mainSHA256'] is None:
            assert not (MAIN / rel).exists()
        else:
            assert digest(MAIN / rel) == row['mainSHA256']
        patch += ''.join(difflib.unified_diff(old.splitlines(True), proposed.read_text().splitlines(True),
            fromfile='a/' + rel if original.exists() else '/dev/null', tofile='b/' + rel))
    assert (ROOT / 'runtime-and-tests.patch').read_text() == patch
    assert digest(ROOT / 'runtime-and-tests.patch') == value['patchSHA256']
    for row in value['unchangedControls']:
        assert digest(base / row['path']) == row['sha256']
        assert (base / row['path']).stat().st_size == row['bytes']

    prefix = 'provider-swift/Sources/ProviderCore/Coordinator/'
    old = (ROOT / 'original' / prefix / 'NativePairRequestBridge.swift').read_text()
    new = (ROOT / 'proposed' / prefix / 'NativePairRequestBridge.swift').read_text()
    assert new.replace('chunkSize:16), pair:pair)', 'chunkSize:16))') == old
    old = (ROOT / 'original' / prefix / 'NativePairRequestExecutionOwner.swift').read_text()
    new = (ROOT / 'proposed' / prefix / 'NativePairRequestExecutionOwner.swift').read_text()
    assert old[old.index('    private func require('):] == new[new.index('    private func require('):]
    tests = list((ROOT / 'proposed/provider-swift/Tests').rglob('*Tests.swift'))
    count = sum(p.read_text().count('@Test func ') for p in tests)
    assert count == 15
    print(json.dumps({'schema': 'protected_member_session_source_check_v1', 'passed': True,
        'overlayFiles': len(value['overlay']), 'unchangedControls': len(value['unchangedControls']),
        'stagedTestMethods': count, 'originalRequestGateExact': True, 'bridgeInverseExact': True,
        'compilerOrSwiftParserExecuted': False, 'fixturesExecuted': False,
        'remoteOrModelActions': False, 'mainModified': False}, sort_keys=True))


if __name__ == '__main__':
    main()
