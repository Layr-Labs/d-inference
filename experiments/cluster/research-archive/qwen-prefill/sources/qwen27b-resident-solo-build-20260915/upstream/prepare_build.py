"""Root-run only: prepare an owned APFS clone; never mutates MAIN or the baseline."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess

DRAFT = Path(__file__).resolve().parent
BUILD = DRAFT.parent / 'qwen9b-resident-solo-generation-build-20260915'
WORK = BUILD / 'workspace'
PACKAGE = Path('experiments/cluster/inference')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def members(root):
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(x for x in dirs if x not in {'.git', '.build', '__pycache__'})
        for name in sorted(files):
            p = Path(directory) / name
            if name != '.git' and not p.is_symlink():
                result[str(p.relative_to(root))] = digest(p)
    return result


def verify_source():
    integration = json.loads((DRAFT / 'integration.json').read_bytes())
    base = integration['base']; origin = Path(base['sourceDirectory'])
    assert digest(Path(base['sourceSnapshot'])) == base['sourceSnapshotSHA256']
    assert digest(Path(base['buildManifest'])) == base['buildManifestSHA256']
    snapshot = json.loads((DRAFT / 'base-source-snapshot.json').read_bytes())
    assert members(origin) == snapshot, 'Baseline source changed'
    for row in integration['files']:
        assert digest(DRAFT / row['source']) == row['sha256'], row['source']
        old = origin / row['target']
        assert (digest(old) if old.exists() else None) == row['baseSHA256'], row['target']
    return integration, origin, snapshot


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--prepare', action='store_true', required=True)
    parser.parse_args()
    integration, origin, before = verify_source()
    assert not BUILD.exists(), 'Refuse to overwrite a prior build or failed attempt'
    BUILD.mkdir(mode=0o700)
    subprocess.run(['/bin/cp', '-cR', str(origin), str(WORK)], check=True)
    rebased = []
    # Clone-owned source and build links must never retain baseline destinations.
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
            assert resolved == WORK or WORK in resolved.parents, 'External cloned link: ' + str(p)
    assert members(WORK) == before
    changes = []
    for row in integration['files']:
        target = WORK / row['target']; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(DRAFT / row['source'], target)
        assert digest(target) == row['sha256']
        changes.append(row['target'])
    rewritten = []
    cache = WORK / PACKAGE / '.build'
    for directory, dirs, files in os.walk(cache, followlinks=False):
        dirs[:] = [x for x in dirs if x not in {'checkouts', 'repositories', '.git'}]
        for name in files:
            p = Path(directory) / name
            if p.is_symlink() or (p.suffix not in {'.json', '.yaml', '.txt'} and name not in {'sources', 'description'}):
                continue
            raw = p.read_bytes(); changed = raw.replace(str(origin).encode(), str(WORK).encode())
            if changed != raw:
                p.write_bytes(changed); rewritten.append(str(p.relative_to(WORK)))
    quarantined = []
    for p in list(cache.glob('**/ModuleCache')):
        if p.is_dir() and not p.is_symlink():
            out = BUILD / ('previous-' + str(p.relative_to(cache)).replace('/', '-'))
            assert not out.exists(); p.rename(out); quarantined.append(out.name)
    assert members(origin) == before
    snapshot = members(WORK)
    (BUILD / 'source-snapshot.json').write_text(json.dumps(snapshot, indent=2, sort_keys=True) + '\n')
    receipt = {'schema': 'resident_solo_build_preparation_v1', 'baselineUnchanged': True,
        'baseSourceCount': len(before), 'preparedSourceCount': len(snapshot), 'overlayTargets': changes,
        'integrationSHA256': digest(DRAFT / 'integration.json'), 'sourceSnapshotSHA256': digest(BUILD / 'source-snapshot.json'),
        'rebasedLinks': rebased, 'rewrittenClonedCacheMetadata': rewritten,
        'quarantinedClonedModuleCaches': quarantined, 'copyMethod': 'APFS cp -cR',
        'modelOrCompilerExecuted': False, 'mainModified': False}
    (BUILD / 'preparation.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'build': str(BUILD), 'preparedSourceCount': len(snapshot), 'modelOrCompilerExecuted': False}))


if __name__ == '__main__':
    main()
