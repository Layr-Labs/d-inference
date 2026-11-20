"""Copy exact local sources and privately clone idle caches; never compile."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')
OVERLAY = ROOT.parent / 'qwen27b-resident-native-adapter-draft-20260915'
WORK = ROOT / 'workspace'
PACKAGES = ['darkbloom-cluster', 'darkbloom-cluster-worker', 'mlx-swift', 'mlx-swift-lm']

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def ignore(path, names):
    return [name for name in names if name in {'.git', '.DS_Store', '__pycache__'}
            or (name.startswith('.build') and (Path(path) / name).is_dir())]

def files(root):
    for current, directories, names in os.walk(root):
        directories[:] = sorted(name for name in directories if name not in {'.git', '__pycache__'}
                                 and not name.startswith('.build'))
        for name in sorted(names):
            if name not in {'.git', '.DS_Store'}:
                yield Path(current) / name

def snapshot(root):
    rows = []
    for path in files(root):
        row = {'path': path.relative_to(root).as_posix()}
        if path.is_symlink():
            row['symlink'] = os.readlink(path)
        else:
            row.update(bytes=path.stat().st_size, sha256=sha(path))
        rows.append(row)
    return sorted(rows, key=lambda row: row['path'])

def write(name, value):
    (ROOT / name).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')

def main():
    assert sha(OVERLAY / 'manifest.json') == '09d4866dac6b6ae53eccd44559fc7367a61d70f07f6b499ee14b3a19396e75b4'
    manifest = json.loads((OVERLAY / 'manifest.json').read_text())
    for row in manifest['members']:
        assert sha(OVERLAY / row['path']) == row['sha256'], row['path']
    WORK.mkdir(mode=0o700, exist_ok=False)
    preimages = []
    for name in PACKAGES:
        source = MAIN / 'libs' / name
        before = snapshot(source)
        shutil.copytree(source, WORK / 'libs' / name, symlinks=True, ignore=ignore)
        assert before == snapshot(source) == snapshot(WORK / 'libs' / name), name
        preimages += [dict(row, path='libs/' + name + '/' + row['path']) for row in before]
    write('main-source-preimages.json', {'root': str(MAIN), 'members': sorted(preimages, key=lambda x:x['path'])})
    integration = json.loads((OVERLAY / 'integration.json').read_text())
    for item in integration['runtimeChanges'] + integration['privateWorkerReplacements']:
        target = WORK / item['path']
        assert sha(target) == item['oldSHA256'] if item['oldSHA256'] else not target.exists(), item['path']
    for patch in ['runtime.patch', 'private-worker.patch', 'native-tests.patch']:
        for phase in [('git','apply','--check'), ('git','apply')]:
            result = subprocess.run([*phase, '--whitespace=error', str(OVERLAY / patch)], cwd=WORK,
                                    capture_output=True, text=True, check=True)
            assert not result.stdout and not result.stderr
    for item in integration['runtimeChanges'] + integration['privateWorkerReplacements']:
        assert sha(WORK / item['path']) == item['newSHA256'], item['path']
    for item in integration['stagedNativeTests']:
        assert (WORK / item['destination']).read_bytes() == (OVERLAY / item['source']).read_bytes()
    rows = snapshot(WORK)
    write('source-snapshot.json', {'root': str(WORK), 'scope': 'Complete four-package source trees, generated caches excluded',
                                  'memberCount': len(rows), 'members': rows})
    cache_source = MAIN / 'libs/darkbloom-cluster-worker/.build-native-worker'
    cache_records = []
    for name, suffix in [('worker', 'darkbloom-cluster-worker/.build-native-worker'),
                         ('runtime', 'darkbloom-cluster/.build-native-runtime')]:
        destination = WORK / 'libs' / suffix
        started = time.monotonic()
        subprocess.run(['/bin/cp', '-cR', str(cache_source), str(destination)], check=True)
        rewritten = []
        for current, directories, names in os.walk(destination):
            directories[:] = [x for x in directories if x not in {'checkouts','repositories','prebuilts','artifacts','ModuleCache'}]
            for name_in_cache in names:
                path = Path(current) / name_in_cache
                if path.is_symlink() or path.suffix not in {'.json','.yaml'}:
                    continue
                data = path.read_bytes()
                changed = data.replace(str(cache_source).encode(), str(destination).encode())
                changed = changed.replace(str(MAIN).encode(), str(WORK).encode())
                if changed != data:
                    rewritten.append({'path': str(path.relative_to(destination)),
                                      'beforeSHA256': hashlib.sha256(data).hexdigest(),
                                      'afterSHA256': hashlib.sha256(changed).hexdigest()})
                    path.write_bytes(changed)
        moved = []
        for path in list(destination.rglob('ModuleCache')):
            if not path.is_dir() or 'checkouts' in path.relative_to(destination).parts:
                continue
            target = ROOT / ('cloned-' + name + '-' + '-'.join(path.relative_to(destination).parts))
            path.rename(target); moved.append({'from': str(path), 'retainedAt': str(target)})
        cache_records.append({'source':str(cache_source),'destination':str(destination),
          'method':'APFS cp -cR, no original cache writes', 'elapsedSeconds':time.monotonic()-started,
          'rewrittenGeneratedPaths':rewritten,'retainedPathDependentModuleCaches':moved})
    # Source snapshot and MAIN inputs remain exact after cache preparation.
    assert rows == snapshot(WORK)
    for item in preimages:
        path = MAIN / item['path']
        assert os.readlink(path) == item['symlink'] if 'symlink' in item else sha(path) == item['sha256']
    write('cache-preparation.json', {'caches':cache_records,'compilerInvoked':False,'mainCacheMutated':False})
    write('preparation.json', {'overlayManifestSHA256':sha(OVERLAY/'manifest.json'),
       'sourceSnapshotSHA256':sha(ROOT/'source-snapshot.json'),'sourceMembers':len(rows),
       'runtimeFiles':8,'privateWorkerReplacements':2,'stagedTestMethods':5,
       'allMainPreimagesUnchanged':True,'compilerInvoked':False,'modelPayloadRead':False,'remoteOperations':False})
    print(json.dumps({'sourceMembers':len(rows),'sourceSnapshotSHA256':sha(ROOT/'source-snapshot.json'),
                      'ownedCaches':len(cache_records),'compilerInvoked':False},indent=2))

if __name__ == '__main__':
    main()
