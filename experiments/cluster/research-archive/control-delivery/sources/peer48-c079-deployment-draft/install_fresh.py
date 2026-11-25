#!/usr/bin/env python3
"""Install frozen c079 into a NEW directory using only explicit local Git bundles.

No fetch, build, native invocation, model access, SSH, or existing checkout edit.
Default --verify-only reads and hashes inputs; --destination opts into installation.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
GIT_MANIFEST = 'e0512837845a765aebd4f14b8e825f4ef99a9ad2e17c67f87c2483bba153ed2b'
PACKAGE_MANIFEST = 'a00f2dc6d12f5e24056cc4bfbf0cd2541c426232deec8c4dc87f09b089026663'
SOURCE_MANIFEST = '38866c940e06a778bf5257d1b5a9c6b88b9292a3ac5d7fd1e63d8323c8a52edb'
PARENT_MANIFEST = '5b6ce0b93cb6e5e5259fd62b2333e1efd062fb6242617d9d8e8fabbe39ab075f'
NATIVE = 'c07954680b1c2d4582d1f200d6dbf850331849fb61b0209ac919a0784c2ba708'
INPUTS = {'prompt.json': '9c6bc7ac937d2daffe5ecdbe7eb3a59aba4f43e96a58a99f08838d4ce48c92ba',
          'teacher.json': '9d1f4e3a2170ce5f947bcdfa249a77885875b0d9d7af88ad3fbc7f7cd7a224fa'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode), 'Not a regular input: ' + str(path))
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    after = path.lstat()
    stable = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(stable(after) == stable(info), 'Input changed while hashing: ' + str(path))
    return h.hexdigest()


def pinned_json(path, expected):
    require(path.stat().st_size <= 1024 * 1024, 'Manifest is oversized')
    require(digest(path) == expected, 'Manifest pin differs: ' + str(path))
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == expected, 'Manifest changed during read')
    return json.loads(raw)


def verify_entry(root, entry, size_key):
    p = root / entry['path']
    require(p.stat().st_size == entry[size_key] and digest(p) == entry['sha256'],
            'File pin differs: ' + str(p))


def git(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0')
    command = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'init.templateDir=',
               '-c', 'protocol.allow=never', '-c', 'protocol.file.allow=always', *map(str, args)]
    result = subprocess.run(command, env=env, check=True, capture_output=True, text=True, timeout=600)
    require(len(result.stdout.encode()) + len(result.stderr.encode()) <= 1024 * 1024,
            'Git output exceeded bound')
    return result.stdout.strip()


def copy_new(source, target, mode):
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    for parent in target.parents:
        require(not parent.is_symlink(), 'Destination ancestor is a symlink')
    before = digest(source)
    with source.open('rb') as src, target.open('xb') as dst:
        shutil.copyfileobj(src, dst, 1024 * 1024)
    target.chmod(mode)
    require(digest(target) == before == digest(source), 'Copy changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--git-transfer', type=Path, required=True)
    parser.add_argument('--native-package', type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--verify-only', action='store_true')
    mode.add_argument('--destination', type=Path)
    args = parser.parse_args()
    require(not any(k.startswith('GIT_') and k not in {'GIT_PAGER', 'GIT_TERMINAL_PROMPT'}
                    for k in os.environ), 'Use an environment without Git repository/config overrides')
    for p in [args.git_transfer, args.native_package]:
        require(p.is_absolute() and p.is_dir() and not p.is_symlink(), 'Explicit input directory required')
    gm = pinned_json(args.git_transfer / 'manifest.json', GIT_MANIFEST)
    pm = pinned_json(args.native_package / 'manifest.json', PACKAGE_MANIFEST)
    sm = pinned_json(args.native_package / 'source-manifest.json', SOURCE_MANIFEST)
    lm = pinned_json(HERE / 'support/parent/manifest.json', PARENT_MANIFEST)
    require(pm['native_sha256'] == NATIVE and len(gm['repositories']) == 6
            and len(pm['files']) == 566 and len(sm['files']) == 403, 'Closed package identity differs')
    for entry in gm['repositories']:
        verify_entry(args.git_transfer, dict(entry, path=entry['bundle']), 'size_bytes')
        require(git('bundle', 'list-heads', args.git_transfer / entry['bundle']) == entry['head'] + ' HEAD',
                'Git bundle advertised identity differs')
    require((args.native_package / 'package.tar').stat().st_size == pm['package_bytes']
            and digest(args.native_package / 'package.tar') == pm['package_sha256'], 'Package tar pin differs')
    for entry in lm['files']:
        verify_entry(HERE / 'support/parent', entry, 'sizeBytes')
    for name, pin in INPUTS.items():
        require(digest(HERE / 'support/inputs' / name) == pin, 'Raw token input differs')
    if args.verify_only:
        print(json.dumps(dict(passed=True, verifiedGitBundles=6, sourceMembers=403,
                              packageSHA256=pm['package_sha256'], nativeSHA256=NATIVE,
                              cloneOrInstallPerformed=False, nativeExecuted=False)))
        return

    dest = args.destination
    require(dest.is_absolute() and dest.parent.is_dir() and not os.path.lexists(dest),
            'Destination must be new with an existing parent')
    require(all(not p.is_symlink() for p in dest.parents), 'Destination ancestor is a symlink')
    dest.mkdir(mode=0o700)
    repo = dest / 'repo'
    # Every clone is real Git history from one of the six verified local bundles.
    for entry in gm['repositories']:
        checkout = repo if entry['path'] == '.' else repo / entry['path']
        if checkout.exists():
            require(checkout.is_dir() and not checkout.is_symlink() and not any(checkout.iterdir()),
                    'Nested Git destination is not empty')
        checkout.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        git('clone', '--no-hardlinks', '--no-checkout', args.git_transfer / entry['bundle'], checkout)
        git('-C', checkout, 'checkout', '--detach', entry['head'])
        git('-C', checkout, 'submodule', 'init')  # Registers URLs; never downloads.
        require(git('-C', checkout, 'rev-parse', 'HEAD') == entry['head'], 'Checkout HEAD differs')

    expected = {e['path']: e for e in pm['files']}
    require(len(expected) == 566, 'Duplicate package member')
    seen = set()
    with tarfile.open(args.native_package / 'package.tar', 'r') as archive:
        for item in archive:
            name = item.name
            p = PurePosixPath(name)
            require(item.isfile() and name in expected and name not in seen
                    and not p.is_absolute() and '..' not in p.parts and str(p) == name, 'Unexpected tar member')
            entry = expected[name]
            require(item.size == entry['size_bytes'] and item.mode == entry['mode'], 'Tar member metadata differs')
            target = repo / name[8:] if name.startswith('overlay/') else dest / name
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            require(all(not q.is_symlink() for q in target.parents), 'Overlay ancestor is a symlink')
            # Existing overlay targets belong only to this newly cloned checkout.
            if target.exists() or target.is_symlink():
                require(target.is_file() and not target.is_symlink(), 'Overlay target is not regular')
            count, checksum = 0, hashlib.sha256()
            with archive.extractfile(item) as source, target.open('wb') as stream:
                for block in iter(lambda: source.read(1024 * 1024), b''):
                    count += len(block)
                    require(count <= item.size, 'Tar member exceeded its bound')
                    checksum.update(block)
                    stream.write(block)
            require(count == item.size and checksum.hexdigest() == entry['sha256'], 'Tar member bytes differ')
            target.chmod(entry['mode'])
            seen.add(name)
    require(seen == set(expected), 'Package is incomplete')
    require(digest(args.native_package / 'package.tar') == pm['package_sha256'], 'Package changed')
    for entry in pm['files']:
        base = repo if entry['path'].startswith('overlay/') else dest
        e = dict(entry, path=entry['path'][8:] if entry['path'].startswith('overlay/') else entry['path'])
        verify_entry(base, e, 'size_bytes')
    for entry in lm['files']:
        copy_new(HERE / 'support/parent' / entry['path'], dest / 'launcher' / entry['path'], 0o400)
    copy_new(HERE / 'support/parent/manifest.json', dest / 'launcher/manifest.json', 0o400)
    for name in INPUTS:
        copy_new(HERE / 'support/inputs' / name, dest / 'inputs' / name, 0o400)

    # Exercise the unchanged archived-source helper against this real checkout.
    spec = importlib.util.spec_from_file_location('_c079_deploy_archive', dest / 'launcher/prefill_compute_archive.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    provenance = dest / 'provenance'
    provenance.mkdir(mode=0o700)
    actual = module.archive_sources(repo / 'experiments/cluster/runtime', provenance)
    require(actual['files'] == sm['files'], 'Fresh archive differs from all 403 frozen source entries')
    require(actual['dependencies']['repository_head'] == pm['repository_head']
            and actual['dependencies']['tracked_dependency_changes'] == '', 'Git dependency provenance differs')
    expected_repos = {e['path']: e['head'] for e in gm['repositories'] if e['path'] != '.'}
    observed = {}
    for line in git('-C', repo, 'submodule', 'status', '--recursive').splitlines():
        # _git strips the outer whitespace; +/-/U remain forbidden on every row.
        fields = line.strip().split()
        require(fields and len(fields[0]) == 40 and fields[0][0] not in '-+U', 'Uninitialized or changed submodule')
        observed[fields[1]] = fields[0]
    require(observed == expected_repos, 'Recursive dependency path/commit set differs')
    receipt = dict(kind='fresh_isolated_c079_deployment', passed=True, repository=str(repo),
                   dependencies=actual['dependencies'], sourceFiles=403, overlayFiles=560,
                   frozenSourceManifestSHA256=SOURCE_MANIFEST,
                   actualSourceManifestSHA256=digest(provenance / 'source-manifest.json'),
                   nativeSHA256=digest(dest / 'bundle/cluster-inference'),
                   bundleManifestSHA256=digest(dest / 'bundle/bundle.json'),
                   nativeExecuted=False, modelAccessed=False, remoteAccessed=False,
                   existingCheckoutModified=False, buildPerformed=False)
    module.write_json(dest / 'install-receipt.json', receipt)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
