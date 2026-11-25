"""Bounded current-source Go qualification for automatic trusted membership."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent
WORK = ROOT / 'workspace'
sys.path.insert(0, str(ROOT.parent / 'gemma4-execution-20260920'))
from build_guard_metrics import bounded


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_inventory():
    paths = [WORK / 'go.mod', WORK / 'go.sum']
    paths += sorted((WORK / 'coordinator').rglob('*.go'))
    return [dict(path=str(p.relative_to(WORK)), bytes=p.stat().st_size, sha256=sha(p)) for p in paths]


def completions(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
    return rows, [(r['Package'], r['Test']) for r in rows if r.get('Action') == 'pass' and 'Test' in r]


def expected_tests():
    _, names = completions(ROOT / 'qualification-1/go-focused-2.log')
    expected = {(p, n) for p, n in names if '/' not in n}
    draft = ROOT.parent / 'cluster-product-app-attest-pair-20260920'
    for row in json.loads((draft / 'staged-tests.json').read_bytes())['methods']:
        if row['language'] == 'Go':
            expected.add(('github.com/eigeninference/d-inference/' + str(Path(row['path']).parent), row['name']))
    draft = ROOT.parent / 'cluster-product-coordinator-composition-20260920'
    for row in json.loads((draft / 'initiation-overlay.json').read_bytes()):
        if row['path'].endswith('_test.go'):
            for name in re.findall(r'^func (Test\w+)\(', (draft / 'proposed' / row['path']).read_text(), re.M):
                expected.add(('github.com/eigeninference/d-inference/' + str(Path(row['path']).parent), name))
    return expected


def main():
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('phase', choices=['focused', 'race'])
    a = p.parse_args()
    applied = ROOT / 'initiation-typed-identity-overlay.json'
    assert sha(applied) == 'edc9ca6570b2e2ad24c1d992a20d07979a5c32e773155bc1c631cf23a9516a0b'
    for row in json.loads(applied.read_bytes())['finalFiles']:
        target = WORK / row['path']
        assert target.stat().st_size == row['bytes'] and sha(target) == row['sha256']
    output = ROOT / 'qualification-2' / a.phase
    output.mkdir(mode=0o700, parents=True)
    before = source_inventory()
    (output / 'source-before.json').write_text(json.dumps(before, indent=2))
    expected = expected_tests()
    packages = ['./coordinator/protocol', './coordinator/registry', './coordinator/appattest/service', './coordinator/api']
    if a.phase == 'race':
        packages = ['./coordinator/registry']
        expected = {(p, n) for p, n in expected if p.endswith('/registry')}
    command = ['/usr/bin/env', 'GOMAXPROCS=2', '/Users/developer/.local/share/mise/installs/go/1.25.0/bin/go',
               'test', '-p', '2', '-count=1', '-json', '-timeout', '180s' if a.phase == 'race' else '120s']
    if a.phase == 'race':
        command += ['-race']
    command += packages + ['-run', 'Test(NativeIdentity|AppAttest|NativePair|VerifiedPair)']
    os.chdir(WORK)
    try:
        bounded(command, output / 'execution.log', timeout=200 if a.phase == 'race' else 160)
    finally:
        after = source_inventory()
        (output / 'source-after.json').write_text(json.dumps(after, indent=2))
        assert before == after
    rows, names = completions(output / 'execution.log')
    tops = [(p, n) for p, n in names if '/' not in n]
    assert all(r.get('Action') not in ('fail', 'skip') for r in rows)
    assert len(tops) == len(set(tops)) and expected <= set(tops), sorted(expected - set(tops))
    package_passes = [r for r in rows if r.get('Action') == 'pass' and 'Test' not in r]
    assert len(package_passes) == len(packages)
    receipt = dict(status='passed', phase=a.phase, topLevelTests=len(tops), totalTestCompletions=len(names),
                   requiredTests=len(expected), packages=len(package_passes), failed=0, skipped=0,
                   sourceInventorySHA256=sha(output / 'source-before.json'), actualLogSHA256=sha(output / 'execution.log'))
    (output / 'validation.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
