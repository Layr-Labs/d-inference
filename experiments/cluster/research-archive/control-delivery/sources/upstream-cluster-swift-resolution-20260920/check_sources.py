"""Verify only explicit small source/metadata inputs; never import product code."""
from pathlib import Path
import difflib
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(row):
    path = Path(row['path'])
    assert path.is_file() and not path.is_symlink(), path
    assert sha(path) == row['sha256'], path
    if 'bytes' in row:
        assert path.stat().st_size == row['bytes'], path


def main():
    manifest = ROOT / 'manifest.json'
    if manifest.exists():
        for row in json.loads(manifest.read_bytes())['members']:
            verify({**row, 'path': str(ROOT / row['path'])})
    plan = json.loads((ROOT / 'integration.json').read_bytes())
    pins = json.loads((ROOT / 'input-pins.json').read_bytes())
    for row in pins['trackedInputs'] + pins['contextInputs']:
        verify(row)
    for key in ('trackedReceipt', 'httpSourceManifest', 'httpSourceReview', 'goResolutionManifest'):
        verify(plan[key])
    for row in plan['changes']:
        verify(row['before'])
        verify(row['after'])
        source = Path(row['after']['path']).read_text()
        assert not re.search(r'^(<<<<<<<|=======|>>>>>>>|\|\|\|\|\|\|\|)', source, re.M)
    assert len(plan['changes']) == 7
    assert sum(row.get('conflictsResolved', 0) for row in plan['changes']) == 9
    primary = plan['changes'][:5]
    threeway = Path(plan['trackedReceipt']['path']).parent
    # Check every byte outside the nine conflict blocks was preserved.
    pattern = re.compile(r'^<<<<<<< cluster-work\n.*?^>>>>>>> current-master\n', re.M | re.S)
    for row in primary:
        original = Path(row['before']['path']).read_text()
        candidate = Path(row['after']['path']).read_text()
        untouched = pattern.split(original)
        cursor = 0
        assert candidate.startswith(untouched[0]) and candidate.endswith(untouched[-1])
        for part in untouched:
            offset = candidate.find(part, cursor)
            assert offset >= 0, row['target']
            cursor = offset + len(part)
    for layer in ('local', 'upstream', 'merged'):
        expected = []
        for row in primary:
            expected.extend(difflib.unified_diff(
                (threeway / layer / row['target']).read_text().splitlines(True),
                Path(row['after']['path']).read_text().splitlines(True),
                fromfile='a/' + row['target'], tofile='b/' + row['target']))
        assert ''.join(expected) == (ROOT / (layer + '-to-resolved.patch')).read_text()
    context_patch = []
    for row in plan['changes'][5:]:
        context_patch.extend(difflib.unified_diff(
            Path(row['before']['path']).read_text().splitlines(True),
            Path(row['after']['path']).read_text().splitlines(True),
            fromfile='a/' + row['target'], tofile='b/' + row['target']))
    assert ''.join(context_patch) == (ROOT / 'context-composition.patch').read_text()
    http_patch = []
    for row in plan['httpRebase']:
        for key in ('before', 'after', 'reviewedHTTPBefore', 'reviewedHTTPAfter'):
            verify(row[key])
        source = Path(row['before']['path']).read_text()
        reviewed = Path(row['reviewedHTTPBefore']['path']).read_text()
        for edit in row['edits']:
            assert source.count(edit['before']) == reviewed.count(edit['before']) == 1
            source = source.replace(edit['before'], edit['after'], 1)
            reviewed = reviewed.replace(edit['before'], edit['after'], 1)
        assert source == Path(row['after']['path']).read_text()
        assert reviewed == Path(row['reviewedHTTPAfter']['path']).read_text()
        http_patch.extend(difflib.unified_diff(
            Path(row['before']['path']).read_text().splitlines(True),
            source.splitlines(True), fromfile='a/' + row['target'], tofile='b/' + row['target']))
    assert ''.join(http_patch) == (ROOT / 'http-over-resolved.patch').read_text()
    old_test = Path(plan['changes'][6]['before']['path']).read_text()
    new_test = Path(plan['changes'][6]['after']['path']).read_text()
    assert re.findall(r'@Test[^\n]*', old_test) == re.findall(r'@Test[^\n]*', new_test)
    assert re.findall(r'#(?:expect|require)[^\n]*', old_test) == re.findall(r'#(?:expect|require)[^\n]*', new_test)
    print(json.dumps({'sourceChecksPassed': True, 'primaryRuntimeFiles': 6,
                      'trackedConflictBlocks': 9, 'existingTestContextUpdates': 1,
                      'httpRebaseFiles': 2, 'compilerExecuted': False,
                      'fixturesExecuted': False, 'mainMutated': False}, sort_keys=True))


if __name__ == '__main__':
    main()
