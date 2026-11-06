"""Exact source composition; cache/source inventory remains the inherited helper."""
import hashlib
import json
import os
from pathlib import Path
from inputs import (BASE, SOURCE, UPSTREAM, UPSTREAM_SHA, OVERLAY, OVERLAY_SHA,
                    B_OVERLAY, B_OVERLAY_SHA)


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
    for root, expected in ((UPSTREAM, UPSTREAM_SHA), (OVERLAY, OVERLAY_SHA), (B_OVERLAY, B_OVERLAY_SHA)):
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
    return declared


def isolated_environment():
    # Exact inherited environment isolation: no live service/database credentials.
    keep = ('PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'SDKROOT')
    selected = {key: os.environ[key] for key in keep if key in os.environ}
    selected.update(GOMAXPROCS='2', GOPROXY='off', GOSUMDB='off', GOTOOLCHAIN='local',
                    GOWORK='off', GOFLAGS='-mod=readonly')
    os.environ.clear(); os.environ.update(selected)
