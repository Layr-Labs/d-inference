"""Build an offline, commit-pinned CI input bundle without mutating user caches."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile

from sandbox_ci_capture import capture, failed

PACKAGES = ('./coordinator/protocol', './coordinator/sandboxhost', './coordinator/sandboxcontrol')
WORKLOAD = 'darkbloom_sandbox_ci_v1'
FIXTURES = Path(__file__).resolve().parents[1] / 'Benchmarks' / 'go-ci'


def validate_output_location(output, *inputs):
    resolved = output.resolve()
    if not output.is_absolute() or output.exists():
        raise ValueError('output must be a new absolute directory')
    if any(resolved.is_relative_to(value.resolve(strict=True)) for value in inputs):
        raise ValueError('output must be outside the repository, SDK, and selected module cache')


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def write_json(path, value):
    encoded = (json.dumps(value, indent=2, allow_nan=False) + '\n').encode()
    temporary = Path(str(path) + '.tmp')
    with temporary.open('xb') as output:
        os.chmod(temporary, 0o600)
        output.write(encoded)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def command(argv, *, cwd=None, env=None, log=None, timeout=300):
    result = capture(argv, cwd=cwd, env=env, timeout=timeout, limit=32 * 1024 * 1024)
    if log:
        Path(log).write_bytes(result['stdout'] + result['stderr'])
        Path(log).chmod(0o600)
    if result['interruption_error'] is not None:
        raise result['interruption_error']
    if failed(result):
        raise RuntimeError(f'{Path(argv[0]).name} failed or exceeded capture/time bounds; see {log or "captured command output"}')
    return result['stdout']


def go_environment(sdk, private, workers):
    for name in ('home', 'gopath', 'cache', 'modules', 'tmp'):
        (private / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    return {'PATH': f'{sdk}/bin:/usr/bin:/bin', 'HOME': str(private / 'home'),
            'GOROOT': str(sdk), 'GOTOOLCHAIN': 'local', 'GOENV': 'off', 'CGO_ENABLED': '0',
            'GOPROXY': 'off', 'GOSUMDB': 'off', 'GOVCS': '*:off', 'GOTELEMETRY': 'off', 'GOWORK': 'off', 'GOMAXPROCS': str(workers),
            'GOPATH': str(private / 'gopath'), 'GOCACHE': str(private / 'cache'),
            'GOMODCACHE': str(private / 'modules'), 'TMPDIR': str(private / 'tmp'),
            'LANG': 'C', 'LC_ALL': 'C', 'TZ': 'UTC'}


def module_escape(value):
    return ''.join('!' + char.lower() if char.isupper() else char for char in value)


def remove_private_tree(directory):
    # Go makes extracted module directories read-only. Change only our private
    # copies so cleanup never chmods or removes the caller's selected cache.
    for current, _, _ in os.walk(directory, followlinks=False):
        os.chmod(current, 0o700, follow_symlinks=False)
    shutil.rmtree(directory)


def seed_download_cache(source, destination, requirements):
    """Read metadata and selected pinned archives; Go extracts into our own cache."""
    download = source / 'cache' / 'download'
    if not download.is_dir():
        raise ValueError('--module-cache must contain cache/download')
    for cached in download.rglob('*.mod'):
        if cached.is_symlink() or not cached.is_file():
            raise ValueError('module metadata must be regular files')
        relative = cached.relative_to(source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(cached, target)
    copied = []
    for requirement in requirements:
        relative = Path('cache/download') / module_escape(requirement['Path']) / '@v'
        version = module_escape(requirement['Version'])
        for suffix in ('.zip', '.ziphash', '.info'):
            original = source / relative / (version + suffix)
            if not original.exists():
                continue  # Unused modules need no zip; missing used inputs fail offline.
            if original.is_symlink() or not original.is_file():
                raise ValueError('module input must be a regular file')
            target = destination / relative / original.name
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copyfile(original, target)
            copied.append({'file': relative.as_posix() + '/' + original.name,
                           'sha256': digest(target), 'bytes': target.stat().st_size})
    return copied


def json_stream(raw):
    decoder = json.JSONDecoder()
    text = raw.decode()
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index == len(text):
            break
        value, index = decoder.raw_decode(text, index)
        yield value


def unpack_tracked_snapshot(archive, target):
    with tarfile.open(archive) as inputs:
        total, count = 0, 0
        for member in inputs:
            total += member.size
            count += 1
            if member.size < 0 or total > 2 * 1024**3 or count > 200000:
                raise ValueError('tracked snapshot exceeds extraction bounds')
            name = Path(member.name)
            if name.is_absolute() or '..' in name.parts or not (member.isdir() or member.isfile()):
                raise ValueError('tracked snapshot contains unsupported paths or links')
            destination = target / name
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with inputs.extractfile(member) as source, destination.open('xb') as output:
                    shutil.copyfileobj(source, output)
                destination.chmod(0o700 if member.mode & 0o111 else 0o600)


def pack_tree(source, output, prefix):
    """Deterministic regular-file archive; do not follow local SDK/source links."""
    inventory = []
    with output.open('xb') as destination, gzip.GzipFile(fileobj=destination, mode='wb', mtime=0, filename='') as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as archive:
            for entry in sorted(source.rglob('*')):
                if entry.is_symlink():
                    raise ValueError(f'archive input contains symlink: {entry.relative_to(source)}')
                if entry.is_dir():
                    continue
                if not entry.is_file():
                    raise ValueError('archive input contains a special file')
                relative = entry.relative_to(source).as_posix()
                header = tarfile.TarInfo(prefix + '/' + relative)
                header.size = entry.stat().st_size
                header.mode = 0o700 if entry.stat().st_mode & 0o111 else 0o600
                with entry.open('rb') as content:
                    archive.addfile(header, content)
                inventory.append({'path': relative, 'sha256': digest(entry), 'bytes': header.size, 'executable': bool(header.mode & 0o111)})
    output.chmod(0o600)
    return inventory


def inventory_digest(inventory):
    content = hashlib.sha256()
    for entry in sorted(inventory, key=lambda value: value['path']):
        content.update(f"{entry['path']}\0{entry['sha256']}\0{entry['bytes']}\0{int(entry['executable'])}\n".encode())
    return content.hexdigest()


def prepare_bundle(repo, revision, sdk, module_cache, output, workers):
    if not sdk.is_absolute() or not module_cache.is_absolute():
        raise ValueError('SDK and module cache must be explicit absolute paths')
    sdk = sdk.resolve(strict=True)
    module_cache = module_cache.resolve(strict=True)
    go = sdk / 'bin' / 'go'
    if go.is_symlink() or not go.is_file():
        raise ValueError('--go-sdk must contain its own regular bin/go executable')
    preparation = output / 'preparation'
    preparation.mkdir(mode=0o700)
    environment = go_environment(sdk, preparation, workers)
    sdk_info = json.loads(command([go, 'env', '-json', 'GOVERSION', 'GOHOSTOS', 'GOHOSTARCH'], env=environment))
    commit = command(['git', '-C', repo, 'rev-parse', '--verify', revision + '^{commit}'], env=environment).decode().strip()
    if len(commit) != 40 or any(char not in '0123456789abcdef' for char in commit):
        raise ValueError('revision did not resolve to an immutable commit')
    source = preparation / 'tracked'
    source.mkdir(mode=0o700)
    tracked_tar = preparation / 'tracked.tar'
    command(['git', '-C', repo, 'archive', '--format=tar', '-o', tracked_tar, commit, 'go.mod', 'go.sum', 'coordinator'], env=environment)
    unpack_tracked_snapshot(tracked_tar, source)
    module = json.loads(command([go, 'mod', 'edit', '-json'], cwd=source, env=environment))
    if module.get('Replace'):
        raise ValueError('source revisions with module replacements require a separately reviewed workload')
    cache_inputs = seed_download_cache(module_cache, preparation / 'modules', module['Require'])
    listed = command([go, 'list', '-deps', '-test', '-json', *PACKAGES], cwd=source, env=environment,
                     log=output / 'dependency-list.jsonl', timeout=300)
    local_directories = set()
    for package in json_stream(listed):
        if package.get('Module', {}).get('Main'):
            local_directories.add(Path(package['Dir']).relative_to(source).as_posix())
    selected = preparation / 'selected'
    selected.mkdir(mode=0o700)
    retained = []
    test_directories = {name.removeprefix('./') for name in PACKAGES}
    for entry in source.rglob('*'):
        if not entry.is_file():
            continue
        relative = entry.relative_to(source)
        parent = relative.parent.as_posix()
        owns = [directory for directory in local_directories if parent == directory or parent.startswith(directory + '/')]
        if relative.as_posix() not in ('go.mod', 'go.sum') and not owns:
            continue
        if entry.name.endswith('_test.go') and parent not in test_directories:
            continue
        target = selected / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(entry, target)
        retained.append(relative.as_posix())
    probe = selected / 'benchmarkprobe'
    probe.mkdir(mode=0o700)
    shutil.copyfile(FIXTURES / 'probe.go.txt', probe / 'main.go')
    command([go, 'mod', 'vendor'], cwd=selected, env=environment, log=output / 'vendor.log', timeout=300)
    command([go, 'list', '-mod=vendor', '-deps', '-test', *PACKAGES, './benchmarkprobe'], cwd=selected,
            env=environment, log=output / 'vendor-check.log', timeout=120)
    source_inventory = pack_tree(selected, output / 'source.tar.gz', 'source')
    sdk_inventory = pack_tree(sdk, output / 'go-sdk.tar.gz', 'go')
    runner = output / 'runner'
    command([go, 'build', '-trimpath', '-buildvcs=false', '-ldflags=-buildid=', '-o', runner, '.'],
            cwd=FIXTURES / 'runner', env=environment, log=output / 'runner-build.log', timeout=180)
    manifest = {'schema_version': 1, 'workload': WORKLOAD, 'source_commit': commit, 'gomaxprocs': workers,
                'go_version': sdk_info['GOVERSION'], 'goos': sdk_info['GOHOSTOS'], 'goarch': sdk_info['GOHOSTARCH'],
                'source_sha256': digest(output / 'source.tar.gz'), 'sdk_sha256': digest(output / 'go-sdk.tar.gz'),
                'source_tree_sha256': inventory_digest(source_inventory), 'sdk_tree_sha256': inventory_digest(sdk_inventory),
                'runner_sha256': digest(runner)}
    write_json(output / 'manifest.json', manifest)
    write_json(output / 'provenance.json', {'manifest': manifest, 'tracked_source_files': sorted(retained),
               'local_dependency_directories': sorted(local_directories), 'module_cache_inputs': cache_inputs,
               'source_files': source_inventory, 'sdk_files': sdk_inventory, 'probe_template_sha256': digest(FIXTURES / 'probe.go.txt')})
    remove_private_tree(preparation)
    return manifest
