"""Exact source composition; cache/source inventory remains the inherited helper."""
import hashlib
import json
import os
from pathlib import Path
from inputs import (BASE, SOURCE, UPSTREAM, UPSTREAM_SHA, OVERLAY, OVERLAY_SHA,
                    B_OVERLAY, B_OVERLAY_SHA, ORIGINAL, ORIGINAL_SHA, FAILED)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')


def verify_frozen(root, expected=None):
    manifest = root / 'manifest.json'
    if expected is not None and sha(manifest) != expected:
        raise ValueError('Freeze changed: ' + str(root))
    for row in json.loads(manifest.read_text())['files']:
        p = root / row['path']
        if not p.is_file() or p.is_symlink() or p.stat().st_size != row['sizeBytes'] or sha(p) != row['sha256']:
            raise ValueError('Frozen input changed: ' + str(p))


def check_preimage(path, expected):
    actual = sha(path) if path.is_file() and not path.is_symlink() else None
    if (path.exists() or path.is_symlink()) != (expected is not None) or actual != expected:
        raise ValueError('MAIN preimage/absence changed: ' + str(path))


def verify_overlay():
    verify_frozen(BASE)
    verify_frozen(ORIGINAL, ORIGINAL_SHA)
    for root, expected in ((UPSTREAM, UPSTREAM_SHA), (OVERLAY, OVERLAY_SHA), (B_OVERLAY, B_OVERLAY_SHA, ORIGINAL, ORIGINAL_SHA, FAILED)):
        verify_frozen(root, expected)
    # Only the 25 member and two B Swift files are composed. The separate Go
    # qualification/integration may proceed without changing this Swift input.
    rows = []
    for root, label in ((OVERLAY, 'member'), (B_OVERLAY, 'native-B')):
        for row in json.loads((root / 'integration.json').read_text())['files']:
            if not row['path'].startswith('provider-swift/'):
                continue
            rows.append(dict(row, sourceLayer=label, sourcePath=str(root / 'proposed' / row['path'])))
    declared = json.loads((BASE / 'swift-integration.json').read_text())
    if rows != declared['files'] or len(rows) != 27 or len({row['path'] for row in rows}) != 27:
        raise ValueError('Swift overlay closure changed')
    for row in rows:
        check_preimage(SOURCE / row['path'], row['baseSHA256'])
        p = Path(row['sourcePath'])
        if not p.is_file() or p.is_symlink() or p.stat().st_size != row['sizeBytes'] or sha(p) != row['proposedSHA256']:
            raise ValueError('Swift proposed source changed: ' + row['path'])
    for row in json.loads((BASE / 'helper-lineage.json').read_text()):
        if sha(BASE / row['local']) != row['sha256']:
            raise ValueError('Owned/inventory helper changed')
    for row in json.loads((BASE / 'binder-review.json').read_text())['sources']:
        if sha(SOURCE / row['path']) != row['sha256']:
            raise ValueError('Reviewed binder context changed')
    for row in json.loads((BASE / 'source-context.json').read_text())['files']:
        p = SOURCE / row['path']
        if not p.is_file() or p.is_symlink() or p.stat().st_size != row['sizeBytes'] or sha(p) != row['sha256']:
            raise ValueError('Swift package/protocol context changed')
    corrected = {row['path']: dict(row) for row in declared['files']}
    corrections = json.loads((BASE / 'integration.json').read_text())['files']
    if len(corrections) != 2 or len({row['path'] for row in corrections}) != 2:
        raise ValueError('Unexpected actor-await correction count')
    for row in corrections:
        original = corrected[row['path']]
        if original['proposedSHA256'] != row['baseSHA256']:
            raise ValueError('Actor-await preimage differs from member freeze')
        for prefix, expected in [('originals', row['baseSHA256']), ('proposed', row['proposedSHA256'])]:
            p = BASE / prefix / row['path']
            if not p.is_file() or p.is_symlink() or sha(p) != expected:
                raise ValueError('Actor-await correction source changed')
        original.update(proposedSHA256=row['proposedSHA256'], sizeBytes=row['sizeBytes'],
                        sourcePath=str(BASE / 'proposed' / row['path']), sourceLayer='actor-await')
    return dict(declared, files=list(corrected.values()))


def isolated_environment():
    # Exact inherited environment isolation: no live service/database credentials.
    keep = ('PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'SDKROOT')
    selected = {key: os.environ[key] for key in keep if key in os.environ}
    selected.update(GOMAXPROCS='2', GOPROXY='off', GOSUMDB='off', GOTOOLCHAIN='local',
                    GOWORK='off', GOFLAGS='-mod=readonly')
    os.environ.clear(); os.environ.update(selected)


def verify_failed_evidence():
    bound = json.loads((BASE / 'failure-inputs.json').read_text())
    if bound['failedRoot'] != str(FAILED):
        raise ValueError('Unexpected failed preparation root')
    for row in bound['files']:
        p = FAILED / row['path']
        if not p.is_file() or p.is_symlink() or p.stat().st_size != row['sizeBytes'] or sha(p) != row['sha256']:
            raise ValueError('Retained failed source/diagnostic evidence changed')
    actual = json.loads((FAILED / 'swift-tests-1/execution.json').read_text())
    if (actual.get('exitCode') != 1 or actual.get('timedOut') is not False
            or actual.get('reaped') is not True or actual.get('groupAbsent') is not True):
        raise ValueError('Failed compiler is not naturally terminal/reaped')
