"""Create only a private clone of the selected qualified ancestry; no compiler."""
import json
import os
from pathlib import Path
import sys
import time
from native_inputs import BASE, DRAFT, paths, require, overlays, sha, source_snapshot, link_snapshot, verify_ancestor, verify_prepared, write
from owned_process import invoke_controller


def main():
    role, = sys.argv[1:]
    spec, root, work, package, cache, binary = paths(role)
    sources, dependencies, links = verify_ancestor(role, spec)
    require(root.parent.resolve() == root.parent and not os.path.lexists(root), 'Fresh canonical private build root required')
    root.mkdir(mode=0o700)
    receipt = dict(role=role, passed=False, compilerInvoked=False, nativeModelOrRemoteExecuted=False,
                   cloneSource=spec['workspaceAncestor'], cloneDestination=str(work),
                   generatedCachePathRewrites=[], retainedModuleCaches=[])
    began = time.monotonic()
    try:
        clone = dict(argv=['/bin/cp', '-cR', spec['workspaceAncestor'], str(work)])
        receipt['clone'] = clone
        try:
            with (root / 'clone.stdout').open('xb') as stdout, (root / 'clone.stderr').open('xb') as stderr:
                invoke_controller(clone['argv'], stdout, stderr, clone, timeout=60)
        finally:
            write(root / 'clone.json', clone)
        require(clone.get('exitCode') == 0 and clone.get('reaped') and clone.get('groupAbsent'), 'Owned APFS clone failed')
        require(source_snapshot(work, role) == sources and link_snapshot(work) == links, 'Cloned source preimage differs')
        require(source_snapshot(cache / 'checkouts', role) == dependencies, 'Cloned dependencies differ')
        for relative, overlay, original in overlays(role, spec):
            target = work / relative
            require(target.read_bytes() == original.read_bytes(), 'Overlay preimage differs')
            target.chmod(target.stat().st_mode | 0o200)
            target.write_bytes(overlay.read_bytes())
        old_work = spec['workspaceAncestor']
        receipt['sourceLinkRewrites'] = []
        for relative, target in links.items():
            if target.startswith(old_work + '/'):
                path = work / relative
                require(path.is_symlink() and os.readlink(path) == target, 'Source link preimage changed')
                new_target = str(work) + target[len(old_work):]
                path.unlink(); path.symlink_to(new_target)
                receipt['sourceLinkRewrites'].append(dict(path=relative, before=target, after=new_target))
        # Same generated-cache rewrite convention as the qualified native runner.
        # Never edit checkout/repository/artifact source or the old cache.
        old_root = str(Path(old_work).parent)
        for current, directories, names in os.walk(cache):
            directories[:] = [x for x in directories if x not in {'checkouts', 'repositories', 'prebuilts', 'artifacts', 'ModuleCache'}]
            for name in names:
                path = Path(current) / name
                if path.is_symlink() or path.suffix not in {'.json', '.yaml', '.yml'}:
                    continue
                before = path.read_bytes()
                after = before.replace(old_root.encode(), str(root).encode())
                if before != after:
                    old_sha = sha(path)
                    path.chmod(path.stat().st_mode | 0o200)
                    path.write_bytes(after)
                    receipt['generatedCachePathRewrites'].append(dict(path=str(path.relative_to(cache)), beforeSHA256=old_sha, afterSHA256=sha(path)))
        for path in list(cache.rglob('ModuleCache')):
            if path.is_dir() and not path.is_symlink() and 'checkouts' not in path.relative_to(cache).parts:
                destination = root / ('retained-prior-' + '-'.join(path.relative_to(cache).parts))
                require(not os.path.lexists(destination), 'Retained module cache destination exists')
                path.rename(destination)
                receipt['retainedModuleCaches'].append(str(destination.relative_to(root)))
        checked = verify_prepared(role)
        write(root / 'source-snapshot.json', checked.pop('actualSource'))
        write(root / 'dependency-snapshot.json', checked.pop('dependencies'))
        receipt.update(checked, passed=True)
    except BaseException as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        receipt['elapsedSeconds'] = time.monotonic() - began
        write(root / 'preparation.json', receipt)
    print(json.dumps(dict(passed=True, role=role, seconds=receipt['elapsedSeconds'],
                          sourceMembers=receipt['sourceMembers'], dependencyMembers=receipt['dependencyMembers'])), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
