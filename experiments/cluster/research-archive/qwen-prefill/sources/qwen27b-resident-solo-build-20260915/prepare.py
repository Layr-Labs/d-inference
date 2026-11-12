"""Root-granted materialization only: fresh APFS clone of the qualified solo ancestor."""
import argparse
import json
import os
from pathlib import Path
import shutil
import time
from build_inputs import BASE, OLD, DRAFT, WORK, CACHE, authority, members, digest, verify, verify_preparation
from owned_process import invoke_controller


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--prepare', action='store_true', required=True)
    parser.parse_args()
    frozen = verify_preparation()
    sources, dependencies, expected, changed_paths = authority()
    origin = OLD / 'workspace'
    if WORK.exists() or WORK.is_symlink():
        raise ValueError('Refuse an existing or failed materialization')
    if members(origin) != sources or members(origin / 'experiments/cluster/inference/.build/checkouts') != dependencies:
        raise ValueError('Qualified solo ancestor changed before clone')
    clone = dict(argv=['/bin/cp', '-cR', str(origin), str(WORK)])
    began = time.monotonic()
    try:
        with (BASE / 'clone.stdout').open('xb') as stdout, (BASE / 'clone.stderr').open('xb') as stderr:
            invoke_controller(clone['argv'], stdout, stderr, clone, timeout=60)
    finally:
        clone['elapsedSeconds'] = time.monotonic() - began
        (BASE / 'clone.json').write_text(json.dumps(clone, sort_keys=True, indent=2) + '\n')
    if clone.get('exitCode') != 0 or not clone.get('reaped') or not clone.get('groupAbsent'):
        raise ValueError('Owned source/cache clone failed or remains unfenced')
    rebased = []
    for directory, dirs, files in os.walk(WORK, followlinks=False):
        for name in dirs + files:
            p = Path(directory) / name
            if not p.is_symlink():
                continue
            target = os.readlink(p)
            if target.startswith(str(origin) + '/'):
                p.unlink(); p.symlink_to(str(WORK) + target[len(str(origin)):])
                rebased.append(str(p.relative_to(WORK)))
            resolved = p.resolve(strict=True)
            if resolved != WORK and WORK not in resolved.parents:
                raise ValueError('External cloned link: ' + str(p))
    if members(WORK) != sources:
        raise ValueError('Cloned source preimage differs')
    for relative in changed_paths:
        target = WORK / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(DRAFT / 'proposed' / relative, target)
        if digest(target) != expected[relative]:
            raise ValueError('Copied solo overlay changed')
    rewritten = []
    for directory, dirs, files in os.walk(CACHE, followlinks=False):
        dirs[:] = [x for x in dirs if x not in {'checkouts', 'repositories', '.git'}]
        for name in files:
            p = Path(directory) / name
            if p.is_symlink() or (p.suffix not in {'.json', '.yaml', '.txt'} and name not in {'sources', 'description'}):
                continue
            raw = p.read_bytes(); value = raw.replace(str(origin).encode(), str(WORK).encode())
            if value != raw:
                p.write_bytes(value); rewritten.append(str(p.relative_to(WORK)))
    quarantined = []
    for p in list(CACHE.glob('**/ModuleCache')):
        if p.is_dir() and not p.is_symlink():
            out = BASE / ('previous-' + str(p.relative_to(CACHE)).replace('/', '-'))
            if out.exists():
                raise ValueError('Prior retained module cache already exists')
            p.rename(out); quarantined.append(out.name)
    checked = verify()
    if verify_preparation() != frozen:
        raise ValueError('Preparation source changed during clone')
    for name, value in [('source-snapshot.json', expected), ('dependency-source-snapshot.json', dependencies)]:
        with (BASE / name).open('x') as stream:
            json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')
    receipt = dict(schema='qwen27b_solo_build_preparation_v1', **checked,
        buildPreparationManifestSHA256=frozen, sourceSnapshotSHA256=digest(BASE / 'source-snapshot.json'),
        dependencySnapshotSHA256=digest(BASE / 'dependency-source-snapshot.json'),
        rebasedLinks=rebased, rewrittenClonedCacheMetadata=rewritten, retainedModuleCaches=quarantined,
        compilerInvoked=False, modelOrRemoteExecuted=False)
    (BASE / 'preparation.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    print(json.dumps(receipt), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
