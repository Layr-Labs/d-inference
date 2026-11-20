"""Freeze the selected-payload-cache worker and its retained source snapshot."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / 'resident-payload-cache-build-20260915'
WORKSPACE = BUILD / 'workspace'
DEST = ROOT / 'resident-payload-cache-package-20260915'
REPO = ROOT.parent / 'd-inference'
SNAPSHOT = '894d27fe66b4b370af46d4c7490a5d3f4624947bd5da8a9825e88b30c6f2a05f'
NATIVE = json.loads((BUILD / 'records/build-1.json').read_bytes())['nativeSHA256']
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def copy(source, relative, expected=None, executable=False):
    assert source.is_file() and not source.is_symlink(), source
    before = digest(source)
    assert expected is None or before == expected, source
    target = DEST / relative
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with source.open('rb') as src, target.open('xb') as dst:
        shutil.copyfileobj(src, dst, 1024 * 1024)
    target.chmod(0o500 if executable else 0o400)
    assert digest(target) == before == digest(source), source


def write(relative, value):
    target = DEST / relative
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with target.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')
    target.chmod(0o400)


def entries(root):
    return [dict(path=p.relative_to(root).as_posix(), size_bytes=p.stat().st_size,
                 sha256=digest(p)) for p in sorted(root.rglob('*')) if p.is_file()]


def git(*args):
    return subprocess.run(['git', '-C', str(REPO), *args], check=True,
                          capture_output=True, text=True, timeout=30).stdout.strip()


def main():
    snapshot = BUILD / 'records/source-snapshot.json'
    assert digest(snapshot) == SNAPSHOT
    sources = json.loads(snapshot.read_bytes())
    assert len(sources['files']) == 426
    assert git('rev-parse', 'HEAD') == '605651bb95d71c1da9bb122107925143e9441973'
    assert git('diff', '--submodule', '--', 'libs') == ''
    submodules = git('submodule', 'status', '--recursive')
    assert all(line.strip()[0] not in '-+U' for line in submodules.splitlines())
    # This fresh package is a source archive, not a fabricated Git checkout.
    DEST.mkdir(mode=0o700)
    for item in sources['files']:
        path = WORKSPACE / item['path']
        assert path.stat().st_size == item['size_bytes']
        copy(path, 'source/' + item['path'], item['sha256'])
    copy(snapshot, 'provenance/source-snapshot.json', SNAPSHOT)
    copy(BUILD / 'records/build-1.json', 'provenance/build-1.json')
    write('provenance/dependencies.json', dict(repository_head=git('rev-parse', 'HEAD'),
          submodules=submodules, tracked_dependency_changes='',
          source_archive_is_git_checkout=False, binary_attestation=False))
    release = WORKSPACE / 'experiments/cluster/inference/.build/arm64-apple-macosx/release'
    copy(release / 'cluster-inference', 'bundle/cluster-inference', NATIVE, executable=True)
    copy(release / 'mlx.metallib', 'bundle/mlx.metallib', METALLIB)
    resource = release / 'mlx-swift-lm_MLXLMCommon.bundle'
    for path in sorted(resource.rglob('*')):
        assert not path.is_symlink()
        if path.is_file():
            copy(path, 'bundle/mlx-swift-lm_MLXLMCommon.bundle/' + path.relative_to(resource).as_posix())
    for name in ('rank_worker.py', 'artifacts.py'):
        copy(WORKSPACE / 'experiments/cluster/runtime' / name, 'bundle/' + name)
    write('bundle/bundle.json', dict(schema_version=1, files=entries(DEST / 'bundle')))
    write('manifest.json', dict(schema='resident_payload_cache_development_package_v1',
          native_sha256=NATIVE, metallib_sha256=METALLIB, source_snapshot_sha256=SNAPSHOT,
          files=entries(DEST), native_executed=False, performance_qualification=False))
    print(json.dumps(dict(package=str(DEST), manifest_sha256=digest(DEST / 'manifest.json'),
          bundle_manifest_sha256=digest(DEST / 'bundle/bundle.json'),
          member_count=len(json.loads((DEST / 'manifest.json').read_bytes())['files']))))


if __name__ == '__main__':
    main()
