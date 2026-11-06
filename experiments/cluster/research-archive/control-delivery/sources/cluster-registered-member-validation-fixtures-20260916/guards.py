"""Source checks only; package materialization is explicit in prepare.py."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
from inputs import BASE, SOURCE, OVERLAY, OVERLAY_SHA, GO_PACKAGES

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')

def verify_overlay():
    manifest = OVERLAY / 'manifest.json'
    if sha(manifest) != OVERLAY_SHA:
        raise ValueError('Member freeze changed')
    for row in json.loads(manifest.read_text())['files']:
        p = OVERLAY / row['path']
        if p.stat().st_size != row['sizeBytes'] or sha(p) != row['sha256']:
            raise ValueError('Frozen member input changed: ' + row['path'])
    integration = json.loads((OVERLAY / 'integration.json').read_text())
    for row in integration['files']:
        p = SOURCE / row['path']
        actual = sha(p) if p.is_file() and not p.is_symlink() else None
        if (p.exists() or p.is_symlink()) != (row['baseSHA256'] is not None) or actual != row['baseSHA256']:
            raise ValueError('MAIN preimage/absence changed: ' + row['path'])
        if sha(OVERLAY / 'proposed' / row['path']) != row['proposedSHA256']:
            raise ValueError('Candidate differs from integration')
    for row in json.loads((BASE / 'helper-lineage.json').read_text()):
        if sha(BASE / row['local']) != row['sha256']:
            raise ValueError('Owned/inventory helper changed')
    for row in json.loads((BASE / 'binder-review.json').read_text())['sources']:
        if sha(SOURCE / row['path']) != row['sha256']:
            raise ValueError('Reviewed binder context changed')
    return integration

def source_for(relative):
    p = OVERLAY / 'proposed' / relative
    return p if p.exists() else SOURCE / relative

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
        candidate_directory = OVERLAY / 'proposed' / package
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
                    matched = list(directory.glob(value))
                    if not matched:
                        raise ValueError('Missing embedded source: ' + value)
                    for p in matched:
                        if not p.is_file() or p.is_symlink():
                            raise ValueError('Expected regular embedded source')
                        paths.add(p.relative_to(SOURCE).as_posix())
        testdata = directory / 'testdata'
        if testdata.exists():
            for p in testdata.rglob('*'):
                if p.is_symlink():
                    raise ValueError('Unexpected fixture symlink')
                if p.is_file():
                    paths.add(p.relative_to(SOURCE).as_posix())
    rows = []
    for relative in sorted(paths):
        p = source_for(relative)
        if not p.is_file() or p.is_symlink():
            raise ValueError('Nonregular Go input')
        rows.append({'path': relative, 'source': 'proposed' if p.is_relative_to(OVERLAY) else 'main',
                     'sizeBytes': p.stat().st_size, 'sha256': sha(p)})
    return {'packages': sorted(seen), 'files': rows}

def verify_go(snapshot, workspace=None):
    # Rediscover the full local source/fixture closure, so an old 1091-file
    # preparation cannot silently omit the newly pinned repository fixtures.
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
