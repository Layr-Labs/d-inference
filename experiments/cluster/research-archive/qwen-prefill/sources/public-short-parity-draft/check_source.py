#!/usr/bin/env python3
"""Public support path/byte checks only. Does not invoke the Swift runner."""
from pathlib import Path
import difflib
import hashlib
import json
import re

D = Path(__file__).resolve().parent
REPO = Path('/Users/developer/DarkbloomDev/d-inference')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run():
    data = json.loads((D/'source-map.json').read_text())
    for pin in [data['source_package'], data['fixture_source_list']]:
        assert digest(Path(pin['path'])) == pin['sha256']
    for pin in data['sources'] + [data['stdin']]:
        path = REPO/pin['target']
        assert path.stat().st_size == pin['bytes'] and digest(path) == pin['sha256'], path
    runner = D/'proposed/experiments/cluster/inference/Tests/ShortParity/run.sh'
    names = re.findall(r'"\$(?:source_dir|test_dir)/([^"\n]+\.swift)"', runner.read_text())
    assert [Path(name).name for name in names] == [Path(pin['target']).name for pin in data['sources']]
    assert len(names) == 40
    assert '../RegisteredDenseProfiles/retained-inputs.json' in runner.read_text()
    assert 'trap \'rm -rf -- "$check_dir"\' EXIT' in runner.read_text()
    patch = ''
    for relative in ['experiments/cluster/inference/README.md', 'docs/developer/test.md']:
        original = D/'originals'/relative
        assert original.read_bytes() == (REPO/relative).read_bytes(), relative
        proposed = D/'proposed'/relative
        patch += ''.join(difflib.unified_diff(original.read_text().splitlines(True), proposed.read_text().splitlines(True),
            fromfile='a/'+relative, tofile='b/'+relative))
    assert patch == (D/'docs.patch').read_text()
    page = D/'proposed/experiments/cluster/inference/QWEN_DENSE_SHORT_PARITY.md'
    links = re.findall(r'\[[^\]]+\]\(([^)]+)\)', page.read_text())
    for link in links:
        target = (page.parent/link).resolve()
        if not target.exists():
            relative = target.relative_to((D/'proposed').resolve())
            assert (REPO/relative).exists(), link
    for file in [page, runner]:
        assert '/Users/' not in file.read_text()
    return dict(kind='public_short_parity_support_source_checks', schema_version=1, passed=True,
        pure_source_files=40, exact_integrated_source_and_shared_stdin_pins=True,
        page_relative_links=len(links), docs_patch_exact=True, no_private_paths_in_new_public_files=True,
        compiler_runner_native_candidate_or_payload_executed=False,
        files={str(p.relative_to(D)):digest(p) for p in sorted((D/'proposed').rglob('*')) if p.is_file()})

if __name__ == '__main__':
    print(json.dumps(run(), indent=2, sort_keys=True))
