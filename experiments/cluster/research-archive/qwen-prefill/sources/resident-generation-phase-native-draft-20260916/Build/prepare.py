"""Create a fresh source tree and private APFS compiler-cache clone, without compiling."""
import json
import os
from pathlib import Path
import stat
import time
from build_inputs import BASE, OLD, DRAFT, WORK, CACHE, authority, relative, sha, snapshot, verify
from owned_process import invoke_controller


def main():
    started = time.monotonic()
    sources, dependencies = authority()
    if snapshot(OLD / 'workspace') != sources:
        raise RuntimeError('Original source differs before copy')
    original_cache = OLD / 'workspace/libs/darkbloom-cluster-worker/.build-native-worker'
    if snapshot(original_cache / 'checkouts') != dependencies:
        raise RuntimeError('Original dependencies differ before clone')
    WORK.mkdir(mode=0o700)
    for row in sources:
        source, destination = OLD / 'workspace' / relative(row['path']), WORK / relative(row['path'])
        destination.parent.mkdir(parents=True, exist_ok=True)
        if 'symlink' in row:
            destination.symlink_to(row['symlink'])
        else:
            with destination.open('xb') as stream:
                stream.write(source.read_bytes())
            destination.chmod(stat.S_IMODE(source.stat().st_mode))
    if snapshot(WORK) != sources:
        raise RuntimeError('Copied source preimage differs')
    for overlay in sorted((DRAFT / 'proposed').rglob('*.swift')):
        rel = overlay.relative_to(DRAFT / 'proposed')
        destination = WORK / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(overlay.read_bytes())
    clone = dict(argv=['/bin/cp', '-cR', str(original_cache), str(CACHE)])
    try:
        with (BASE / 'clone.stdout').open('xb') as stdout, (BASE / 'clone.stderr').open('xb') as stderr:
            invoke_controller(clone['argv'], stdout, stderr, clone, timeout=60)
    finally:
        (BASE / 'clone.json').write_text(json.dumps(clone, indent=2) + '\n')
    if clone['exitCode'] != 0 or not clone.get('reaped') or not clone.get('groupAbsent'):
        raise RuntimeError('Owned APFS clone failed or group remains')
    rewrites = []
    for current, directories, names in os.walk(CACHE):
        directories[:] = [x for x in directories if x not in {'checkouts', 'repositories', 'prebuilts', 'artifacts', 'ModuleCache'}]
        for name in names:
            path = Path(current) / name
            if path.is_symlink() or path.suffix not in {'.json', '.yaml', '.yml'}:
                continue
            before = path.read_bytes()
            after = before.replace(str(OLD).encode(), str(BASE).encode())
            if before != after:
                old_sha = sha(path)
                path.write_bytes(after)
                rewrites.append(dict(path=str(path.relative_to(CACHE)), beforeSHA256=old_sha, afterSHA256=sha(path)))
    moved = []
    for path in list(CACHE.rglob('ModuleCache')):
        if path.is_dir() and not path.is_symlink() and 'checkouts' not in path.relative_to(CACHE).parts:
            destination = BASE / ('retained-prior-' + '-'.join(path.relative_to(CACHE).parts))
            path.rename(destination)
            moved.append(str(destination.relative_to(BASE)))
    checked = verify()
    for name, root in [('source-snapshot-1.json', WORK), ('dependency-snapshot-1.json', CACHE / 'checkouts')]:
        rows = snapshot(root)
        with (BASE / name).open('x') as stream:
            json.dump(dict(root=str(root), memberCount=len(rows), members=rows), stream, indent=2)
            stream.write('\n')
    result = dict(**checked, cacheCloneSource=str(original_cache), cacheCloneDestination=str(CACHE),
        generatedCachePathRewrites=rewrites, retainedModuleCaches=moved,
        elapsedSeconds=time.monotonic() - started, compilerInvoked=False, modelOrRemoteExecuted=False)
    (BASE / 'preparation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(prepared=True, **checked, elapsedSeconds=result['elapsedSeconds'])))


if __name__ == '__main__':
    os.umask(0o077)
    main()
