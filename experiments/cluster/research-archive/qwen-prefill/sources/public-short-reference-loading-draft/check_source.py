#!/usr/bin/env python3
"""Check support bytes and paths without running Swift, native code or fixtures."""
import ast
import difflib
import hashlib
import json
from pathlib import Path
import re

D = Path(__file__).resolve().parent
REPO = Path('/Users/developer/DarkbloomDev/d-inference')
ROOT = D.parent
PROPOSED = D / 'proposed'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    m = json.loads((D / 'source-map.json').read_text())
    test = Path('experiments/cluster/inference/Tests/ShortReferenceLoading')
    source = Path('experiments/cluster/inference/Sources/ClusterInference')
    run = (PROPOSED / test / 'run.sh').read_text()
    paths = []
    for line in run.splitlines():
        hit = re.fullmatch(r'  "\$(source_dir|test_dir)/([^\"]+\.swift)" \\', line)
        if hit:
            base = source if hit[1] == 'source_dir' else test
            paths.append(str((REPO / base / hit[2]).resolve().relative_to(REPO)))
    assert paths == [x['path'] for x in m['orderedSwiftInputs']] and len(paths) == 38
    for x in m['orderedSwiftInputs'] + m['integratedRuntimeAndFixtureFiles'] + m['additionalDocumentSources']:
        file = REPO / x['path']
        assert sha(file) == x['sha256'] and file.stat().st_size == x['bytes'], x['path']
    assert sha(REPO / m['sharedStdin']) == m['sharedStdinSHA256']
    assert (REPO / m['sharedStdin']).stat().st_size == m['sharedStdinBytes']
    assert '"$test_dir/../RegisteredDenseProfiles/retained-inputs.json"' in run
    assert '-parse-as-library -swift-version 6 -warnings-as-errors' in run
    assert 'trap \'rm -rf -- "$check_dir"\' EXIT' in run
    assert '[[ $# -gt 1 ]]' in run and 'exit 2' in run
    assert '--model-dir' not in run and 'curl ' not in run and 'swift run' not in run
    for version, pin_key in [('registered-dense-short-reference-load-draft', 'v1ManifestSHA256'),
                             ('registered-dense-short-reference-load-v2-draft', 'v2ManifestSHA256')]:
        assert sha(ROOT / version / 'manifest.json') == m[pin_key]
    assert sha(ROOT / 'registered-dense-short-reference-load-v2-draft/fixture-source-list.json') == m['inheritedFixtureSourceListSHA256']
    patches = []
    for name in m['documentOrder']:
        assert sha(REPO / name) == m['documentBases'][name], name
        patches.append(''.join(difflib.unified_diff(
            (REPO / name).read_text().splitlines(True), (PROPOSED / name).read_text().splitlines(True),
            fromfile='a/' + name, tofile='b/' + name)))
    assert (D / 'docs.patch').read_text() == ''.join(patches)
    page = Path('experiments/cluster/inference/QWEN_DENSE_SHORT_REFERENCE_LOADING.md')
    doc = (PROPOSED / page).read_text()
    assert doc.splitlines()[2] == '> Last updated: 2026-09-14 · commit `e4df336bc`'
    for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)', doc):
        assert '://' not in target
        relative = (REPO / page.parent / target.split('#')[0]).resolve().relative_to(REPO)
        assert (PROPOSED / relative).is_file() or (REPO / relative).is_file(), relative
    for literal in ['22 accepted / 101\nrejected', 'public runner execution remains pending',
                    'has no CLI entry', 'max(6 GiB, R + 2H + Q + 4 GiB)',
                    'R + H + Q + 2 GiB', 'Absolute reported swap use is zero',
                    'reclaimable memory is diagnostic only', 'whole-process peak',
                    'do\nnot run the private owner or materializer', 'QWEN_DENSE_SHORT_LEDGER.md']:
        assert literal in doc, literal
    assert not list(PROPOSED.rglob('*.swift')) and not list(PROPOSED.rglob('*.json'))
    proposed_files = [x for x in PROPOSED.rglob('*') if x.is_file()]
    assert len(proposed_files) == 4
    for file in proposed_files:
        assert '/Users/' not in file.read_text() and '\\+' not in file.read_text(), file
    ast.parse(Path(__file__).read_text(), feature_version=(3, 9))
    return {'kind': 'public_short_reference_loading_source_check', 'schemaVersion': 1,
            'result': 'passed', 'orderedSwiftInputs': 38, 'integratedFilesVerified': 8,
            'proposedFiles': 4, 'sharedMetadataReused': True, 'frozenHistoryUnchanged': True,
            'publicRunnerExecuted': False, 'compilerNativeOrModelExecuted': False,
            'modelPayloadOrCandidateAccessed': False}


if __name__ == '__main__':
    print(json.dumps(check(), sort_keys=True, indent=2))
