"""After root releases the timing hold, materialize only the pinned source set."""
from pathlib import Path
import hashlib
import json
import os
import stat
import time

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen-mtp-target-verification-build-20260915'
DRAFT = BASE.parent / 'qwen-mtp-target-session-draft-20260915'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(value):
    path = Path(value)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError('Source manifest path is not relative')
    return path


def checked_bytes(path, row):
    raw = path.read_bytes()
    if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
        raise RuntimeError('Pinned source changed: ' + str(path))
    if path.is_symlink():
        raise RuntimeError('The passed source snapshot has no symlinks')
    return raw


def main():
    started = time.monotonic()
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    for path, expected in [
        (OLD / 'source-snapshot-1.json', lineage['baseSourceSnapshotSHA256']),
        (OLD / 'dependency-snapshot-1.json', lineage['baseDependencySnapshotSHA256']),
        (OLD / 'handoff/manifest.json', lineage['baseHandoffManifestSHA256']),
        (DRAFT / 'manifest.json', lineage['draftManifestSHA256']),
        (BASE / 'runtime.patch', lineage['runtimePatchSHA256']),
        (Path(lineage['resourceReview']), lineage['resourceReviewSHA256']),
    ]:
        if sha(path) != expected:
            raise RuntimeError('Source authority pin changed: ' + str(path))
    source_rows = json.loads((OLD / 'source-snapshot-1.json').read_bytes())['members']
    overlays = json.loads((BASE / 'integration.json').read_bytes())['files']
    if overlays != lineage['copiedOverlayFiles'] or len(overlays) != 10:
        raise RuntimeError('Reviewed overlay inventory changed')
    for row in source_rows:
        checked_bytes(OLD / 'workspace' / relative(row['path']), row)
    for row in overlays:
        path = relative(row['path'])
        if sha(BASE / 'overlay' / path) != row['sha256']:
            raise RuntimeError('Reviewed overlay source changed')
        original = OLD / 'workspace' / path
        if row['originalSHA256'] is None:
            if original.exists():
                raise RuntimeError('New overlay unexpectedly replaces a base file')
        elif sha(original) != row['originalSHA256']:
            raise RuntimeError('Reviewed overlay preimage changed')

    workspace = BASE / 'workspace'
    workspace.mkdir(mode=0o700)  # Never reuse an interrupted or prior build tree.
    for row in source_rows:
        path = relative(row['path'])
        source, destination = OLD / 'workspace' / path, workspace / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as stream:
            stream.write(checked_bytes(source, row))
        destination.chmod(stat.S_IMODE(source.stat().st_mode))
    for row in overlays:
        destination = workspace / relative(row['path'])
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((BASE / 'overlay' / relative(row['path'])).read_bytes())
        if sha(destination) != row['sha256']:
            raise RuntimeError('Materialized overlay differs')
    overlay_by_path = {row['path']: row for row in overlays}
    for row in source_rows:
        checked_bytes(OLD / 'workspace' / relative(row['path']), row)
        if row['path'] not in overlay_by_path:
            checked_bytes(workspace / relative(row['path']), row)
    result = dict(baseSourcesCopied=len(source_rows), overlayFiles=len(overlays),
                  expectedSourceFiles=len(source_rows) + sum(row['originalSHA256'] is None for row in overlays),
                  workspace=str(workspace), baseSourceSnapshotSHA256=lineage['baseSourceSnapshotSHA256'],
                  draftManifestSHA256=lineage['draftManifestSHA256'], elapsedSeconds=time.monotonic()-started,
                  sourceOnly=True, compilerExecuted=False, cacheCloned=False,
                  priorWorkspaceModified=False, mainModified=False, modelGPUOrRemoteExecuted=False)
    with (BASE / 'source-preparation.json').open('x') as stream:
        json.dump(result, stream, indent=2); stream.write('\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    os.umask(0o077)
    main()
