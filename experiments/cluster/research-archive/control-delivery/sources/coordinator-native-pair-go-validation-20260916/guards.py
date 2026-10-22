"""Source checks only; package materialization is explicit in prepare.py."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
from inputs import (BASE, SOURCE, OVERLAY, OVERLAY_SHA, B_OVERLAY, B_OVERLAY_SHA,
                    CORRECTION, CORRECTION_SHA, UPSTREAM, UPSTREAM_SHA, GO_PACKAGES)

# First existing file wins. No overlay ever mutates the lower layer.
SOURCE_ROOTS = (CORRECTION / 'proposed', B_OVERLAY / 'proposed', OVERLAY / 'proposed', SOURCE)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')

def verify_frozen(root, expected):
    manifest = root / 'manifest.json'
    if sha(manifest) != expected:
        raise ValueError('Freeze changed: ' + str(root))
    for row in json.loads(manifest.read_text())['files']:
        p = root / row['path']
        if not p.is_file() or p.is_symlink() or p.stat().st_size != row['sizeBytes'] or sha(p) != row['sha256']:
            raise ValueError('Frozen input changed: ' + str(p))

def check_preimage(path, expected):
    actual = sha(path) if path.is_file() and not path.is_symlink() else None
    if (path.exists() or path.is_symlink()) != (expected is not None) or actual != expected:
        raise ValueError('Preimage/absence changed: ' + str(path))

def verify_overlay():
    for root, expected in ((UPSTREAM, UPSTREAM_SHA), (OVERLAY, OVERLAY_SHA),
                           (B_OVERLAY, B_OVERLAY_SHA), (CORRECTION, CORRECTION_SHA)):
        verify_frozen(root, expected)
    integration = json.loads((OVERLAY / 'integration.json').read_text())
    for row in integration['files']:
        check_preimage(SOURCE / row['path'], row['baseSHA256'])
        if sha(OVERLAY / 'proposed' / row['path']) != row['proposedSHA256']:
            raise ValueError('Candidate differs from integration')
    for row in json.loads((B_OVERLAY / 'integration.json').read_text())['files']:
        member = OVERLAY / 'proposed' / row['path']
        effective = member if member.exists() or member.is_symlink() else SOURCE / row['path']
        check_preimage(effective, row['baseSHA256'])
        check_preimage(SOURCE / row['path'], row['mainSHA256'])
        if sha(B_OVERLAY / 'proposed' / row['path']) != row['proposedSHA256']:
            raise ValueError('B candidate differs from integration')
    for row in json.loads((CORRECTION / 'integration.json').read_text())['files']:
        lower = next((root / row['path'] for root in SOURCE_ROOTS[1:]
                      if (root / row['path']).exists() or (root / row['path']).is_symlink()), SOURCE / row['path'])
        check_preimage(lower, row['baseSHA256'])
        if sha(CORRECTION / 'proposed' / row['path']) != row['proposedSHA256']:
            raise ValueError('Cancellation correction differs from integration')
    for row in json.loads((B_OVERLAY / 'source-pins.json').read_text())['files']:
        p = Path(row['path'])
        if not p.is_file() or p.is_symlink() or p.stat().st_size != row['sizeBytes'] or sha(p) != row['sha256']:
            raise ValueError('B source dependency changed: ' + str(p))
    for row in json.loads((BASE / 'helper-lineage.json').read_text()):
        if sha(BASE / row['local']) != row['sha256']:
            raise ValueError('Owned/inventory helper changed')
    for row in json.loads((BASE / 'binder-review.json').read_text())['sources']:
        if sha(SOURCE / row['path']) != row['sha256']:
            raise ValueError('Reviewed binder context changed')
    return integration

def source_for(relative):
    return next((root / relative for root in SOURCE_ROOTS
                 if (root / relative).exists() or (root / relative).is_symlink()), SOURCE / relative)

def go_fixture_inputs():
    expected = {
        'fixtures/prompt-contract/v1/production_vectors.json',
        'deploy/gcp/prod/release-env-defaults',
        'deploy/environments/prod.env',
        'deploy/gcp/prod/required-env-keys.txt',
        'scripts/install.sh',
    }
    rows = json.loads((BASE / 'fixture-inputs.json').read_text())['files']
    if len(rows) != len(expected) or {row['path'] for row in rows} != expected:
        raise ValueError('Explicit Go fixture closure differs')
    for row in rows:
        p = SOURCE / row['path']
        if not p.is_file() or p.is_symlink() or p.stat().st_size != row['sizeBytes'] or sha(p) != row['sha256']:
            raise ValueError('Pinned Go fixture changed: ' + row['path'])
    return rows

def go_snapshot():
    # Conservative local import closure, including test imports on every host.
    # No go list/tool download/compiler is needed to construct this snapshot.
    prefix = 'github.com/eigeninference/d-inference/'
    pending, seen, paths = list(GO_PACKAGES), set(), {'go.mod', 'go.sum'}
    paths.update(row['path'] for row in go_fixture_inputs())
    pattern = re.compile(r'(?m)^import[ \t]+(?:\(([\s\S]*?)^\)|([^\n]+))')
    while pending:
        package = pending.pop()
        if package in seen:
            continue
        if not package.startswith('coordinator/') or '..' in Path(package).parts:
            raise ValueError('Unexpected local Go dependency: ' + package)
        seen.add(package)
        directory = SOURCE / package
        if not directory.is_dir():
            raise ValueError('Missing local Go package: ' + package)
        candidates = {p.name for p in directory.iterdir() if p.is_file() and p.suffix in ('.go', '.s', '.h', '.c', '.cc', '.cpp', '.m', '.mm')}
        for root in SOURCE_ROOTS[:-1]:
            candidate_directory = root / package
            if candidate_directory.exists():
                candidates.update(p.name for p in candidate_directory.iterdir() if p.suffix == '.go')
        for name in sorted(candidates):
            relative = package + '/' + name; paths.add(relative)
            if not name.endswith('.go'):
                continue
            text = source_for(relative).read_text()
            for match in pattern.finditer(text):
                for value in re.findall(r'"([^"\n]+)"', match.group(1) or match.group(2)):
                    if value.startswith(prefix):
                        pending.append(value[len(prefix):])
            for match in re.finditer(r'(?m)^//go:embed[ \t]+([^\n]+)', text):
                for value in shlex.split(match.group(1)):
                    if value.startswith('all:') or '..' in Path(value).parts or value.startswith('/'):
                        raise ValueError('Unsupported embedding pattern')
                    matched = [(root, p) for root in SOURCE_ROOTS for p in (root / package).glob(value)]
                    if not matched:
                        raise ValueError('Missing embedded source: ' + value)
                    for root, p in matched:
                        if not p.is_file() or p.is_symlink():
                            raise ValueError('Expected regular embedded source')
                        paths.add(p.relative_to(root).as_posix())
        for root in SOURCE_ROOTS:
            testdata = root / package / 'testdata'
            if testdata.exists():
                for p in testdata.rglob('*'):
                    if p.is_symlink():
                        raise ValueError('Unexpected fixture symlink')
                    if p.is_file():
                        paths.add(p.relative_to(root).as_posix())
    rows = []
    for relative in sorted(paths):
        p = source_for(relative)
        if not p.is_file() or p.is_symlink():
            raise ValueError('Nonregular Go input')
        origin = next(label for root, label in zip(SOURCE_ROOTS, ('correction', 'native-B', 'member', 'main')) if p.is_relative_to(root))
        rows.append({'path': relative, 'source': origin,
                     'sizeBytes': p.stat().st_size, 'sha256': sha(p)})
    return {'packages': sorted(seen), 'files': rows}

def verify_go(snapshot, workspace=None):
    # Rediscover all layers, including the B public vector and correction test;
    # an earlier member-only preparation cannot satisfy this inventory.
    if snapshot != json.loads((BASE / 'source-preview.json').read_text()):
        raise ValueError('Go inventory differs from the reviewed source freeze')
    if go_snapshot() != snapshot:
        raise ValueError('Go source/fixture closure changed or incomplete')
    for row in snapshot['files']:
        for p in [source_for(row['path'])] + ([workspace / row['path']] if workspace is not None else []):
            if not p.is_file() or p.is_symlink() or p.stat().st_size != row['sizeBytes'] or sha(p) != row['sha256']:
                raise ValueError('Go source changed: ' + row['path'])

def isolated_environment():
    # Retain toolchain/home/cache locations, not live service/database credentials.
    keep = ('PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'SDKROOT')
    selected = {key: os.environ[key] for key in keep if key in os.environ}
    selected.update(GOMAXPROCS='2', GOPROXY='off', GOSUMDB='off', GOTOOLCHAIN='local',
                    GOWORK='off', GOFLAGS='-mod=readonly')
    os.environ.clear(); os.environ.update(selected)
