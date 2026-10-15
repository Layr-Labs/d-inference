"""Immutable source/bundle provenance for the future root-run launcher."""

import hashlib
import importlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n')
    path.chmod(0o600)


def _git(repository, *arguments):
    result = subprocess.run(['git', '-C', str(repository), *arguments], check=True,
                            capture_output=True, text=True, timeout=30)
    if len(result.stdout.encode()) > 1024 * 1024:
        raise ValueError('Dependency provenance output exceeded its bound')
    return result.stdout.strip()


def dependency_identity(repository):
    dirty = _git(repository, 'submodule', 'foreach', '--recursive', '--quiet',
                 'git status --porcelain --untracked-files=no')
    if dirty:
        raise ValueError('Tracked dependency changes must be resolved before a pinned transport run')
    return dict(repository_head=_git(repository, 'rev-parse', 'HEAD'),
                submodules=_git(repository, 'submodule', 'status', '--recursive'),
                tracked_dependency_changes=dirty)


def archive_sources(runtime, output):
    runtime = runtime.resolve(strict=True)
    repository = runtime.parents[2]
    if runtime != repository / 'experiments/cluster/runtime':
        raise ValueError('--runtime must identify this repository\'s experiments/cluster/runtime')
    inference = runtime.parent / 'inference'
    paths = set(inference.joinpath('Sources').rglob('*.swift'))
    paths.update(runtime.rglob('*.py'))
    paths.update(path for path in runtime.rglob('*.md'))
    required = [inference / name for name in ('Package.swift', 'Package.resolved', 'build.sh', 'prepare_dependencies.py')]
    required += [repository / name for name in ('.gitmodules', 'libs/mlx-swift/Package.swift', 'libs/mlx-swift-lm/Package.swift')]
    for path in required:
        if not path.is_file():
            raise ValueError('Missing source/provenance file: ' + str(path))
    paths.update(required)
    if not any(path.suffix == '.swift' and 'Sources' in path.parts for path in paths):
        raise ValueError('No inference sources found')
    destination = output / 'source'
    destination.mkdir(mode=0o700)
    entries = []
    for path in sorted(paths):
        if path.is_symlink() or not path.resolve().is_relative_to(repository):
            raise ValueError('Source snapshot rejects symlink/outside source files')
        relative = path.relative_to(repository)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        before = digest(path)
        shutil.copyfile(path, target)
        if digest(target) != before or digest(path) != before:
            raise ValueError('Source changed during immutable snapshot: ' + str(relative))
        target.chmod(0o400)
        entries.append(dict(path=relative.as_posix(), size_bytes=target.stat().st_size, sha256=before))
    manifest = dict(schema_version=1, repository=str(repository), files=entries,
                    dependencies=dependency_identity(repository))
    write_json(output / 'source-manifest.json', manifest)
    return manifest


def archive_launcher(output):
    folder = Path(__file__).parent
    destination = output / 'launcher'
    destination.mkdir(mode=0o700)
    entries = []
    for source in sorted(folder.glob('*.py')):
        target = destination / source.name
        before = digest(source)
        shutil.copyfile(source, target)
        if digest(source) != before or digest(target) != before:
            raise ValueError('Launcher source changed during snapshot')
        target.chmod(0o400)
        entries.append(dict(path=source.name, sha256=before, size_bytes=target.stat().st_size))
    return entries


def load_archived_runtime(output, epoch):
    package = output / 'source/experiments/cluster/runtime'
    name = '_stage_rank_runtime_' + epoch
    spec = importlib.util.spec_from_file_location(name, package / '__init__.py',
                                                 submodule_search_locations=[str(package)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return {part: importlib.import_module(name + '.' + part)
            for part in ('bundle', 'artifacts', 'configuration', 'processes')}


def verify_archive(runtime_modules, output, source_manifest, bundle_hash, launcher_entries):
    repository = Path(source_manifest['repository'])
    for entry in source_manifest['files']:
        for path in (repository / entry['path'], output / 'source' / entry['path']):
            if path.stat().st_size != entry['size_bytes'] or digest(path) != entry['sha256']:
                raise ValueError('Source drift: ' + entry['path'])
    if dependency_identity(repository) != source_manifest['dependencies']:
        raise ValueError('Dependency identity changed')
    bundle = output / 'bundle'
    if digest(bundle / 'bundle.json') != bundle_hash:
        raise ValueError('Bundle manifest changed')
    runtime_modules['artifacts'].verify_files(bundle, json.loads((bundle / 'bundle.json').read_text())['files'])
    for entry in launcher_entries:
        for path in (Path(__file__).parent / entry['path'], output / 'launcher' / entry['path']):
            if digest(path) != entry['sha256']:
                raise ValueError('Launcher source drift: ' + entry['path'])
