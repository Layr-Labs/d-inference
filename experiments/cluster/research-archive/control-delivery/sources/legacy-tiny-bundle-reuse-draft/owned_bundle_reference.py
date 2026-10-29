"""Explicit reference to an owned read-only bundle; no copy or shared cache manager."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat


def require(value, message):
    if not value:
        raise ValueError(message)


def _pin(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid bundle pin')


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate bundle manifest key')
        result[key] = value
    return result


def _checked(source, expected_manifest, expected_native, archived_runtime, artifacts):
    _pin(expected_manifest)
    _pin(expected_native)
    require(source.is_dir() and not source.is_symlink(), 'Bundle realpath is not a directory')
    actual_files, actual_dirs = set(), set()
    for directory, dirs, files in os.walk(source, followlinks=False):
        for path in [Path(directory)] + [Path(directory)/n for n in dirs+files]:
            info = path.lstat()
            require(info.st_uid == os.geteuid() and not stat.S_ISLNK(info.st_mode),
                    'Bundle member is not owned or contains a symlink')
            relative = path.relative_to(source).as_posix()
            if stat.S_ISDIR(info.st_mode):
                require(info.st_mode & 0o022 == 0, 'Bundle directory permits external writes')
                actual_dirs.add(relative)
            else:
                require(stat.S_ISREG(info.st_mode) and info.st_mode & 0o222 == 0,
                        'Bundle member is not a read-only regular file')
                actual_files.add(relative)
            require(len(actual_files) <= 129 and len(actual_dirs) <= 129, 'Bundle tree is oversized')
    manifest = source/'bundle.json'
    require(manifest.stat().st_size <= 1024**2, 'Bundle manifest is oversized')
    with manifest.open('rb') as stream:
        raw = stream.read(1024**2+1)
    require(len(raw) <= 1024**2 and hashlib.sha256(raw).hexdigest() == expected_manifest,
            'Bundle manifest pin differs')
    data = json.loads(raw, object_pairs_hook=_pairs)
    require(type(data) is dict and set(data) == {'schema_version','files'} and
            type(data['schema_version']) is int and data['schema_version'] == 1 and
            type(data['files']) is list and 1 <= len(data['files']) <= 128,
            'Invalid bundle manifest schema')
    names, directories = set(), {'.'}
    for entry in data['files']:
        require(type(entry) is dict and set(entry) == {'path','size_bytes','sha256'},
                'Invalid bundle entry schema')
        name = entry['path']
        require(type(name) is str and '\\' not in name, 'Invalid bundle path')
        path = PurePosixPath(name)
        require(not path.is_absolute() and '..' not in path.parts and path.parts and
                str(path) == name and name not in names and name != 'bundle.json',
                'Invalid or duplicate bundle member')
        names.add(name)
        directories.update(parent.as_posix() for parent in path.parents)
    require(actual_files == names | {'bundle.json'} and actual_dirs == directories,
            'Bundle tree differs from manifest')
    digests = artifacts.verify_files(source, data['files'])
    require(digests.get('cluster-inference') == expected_native and
            (source/'cluster-inference').stat().st_mode & stat.S_IXUSR,
            'Reused executable identity or owner execution permission differs')
    for name in ('rank_worker.py','artifacts.py'):
        current = archived_runtime/name
        require(current.is_file() and not current.is_symlink() and name in digests and
                artifacts.file_sha256(current) == digests[name],
                'Reused runtime helper differs from fresh source archive')
    require(artifacts.file_sha256(manifest) == expected_manifest, 'Bundle manifest changed during validation')
    return dict(manifestSHA256=expected_manifest, expectedNativeSHA256=expected_native,
                verifiedFileCount=len(digests), runtimeFilesSHA256={n:digests[n] for n in ('rank_worker.py','artifacts.py')})


def create_reference(source, destination, expected_manifest, expected_native, archived_runtime, artifacts):
    """Validate the explicit source and create only a destination symlink."""
    requested = Path(source).absolute()
    resolved = requested.resolve(strict=True)
    destination = Path(destination)
    require(not destination.exists() and not destination.is_symlink(), 'Bundle destination already exists')
    record = _checked(resolved, expected_manifest, expected_native, Path(archived_runtime), artifacts)
    require(requested.resolve(strict=True) == resolved, 'Requested bundle realpath changed')
    destination.symlink_to(resolved, target_is_directory=True)
    return dict(kind='owned_read_only_bundle_reference', schemaVersion=1,
                requestedPath=str(requested), resolvedPath=str(resolved), copied=False, **record)


def check_reference(destination, record, archived_runtime, artifacts):
    """Recheck realpaths, ownership, file bytes and current archived helper identity."""
    destination, requested, resolved = Path(destination), Path(record['requestedPath']), Path(record['resolvedPath'])
    require(destination.is_symlink() and destination.resolve(strict=True) == resolved and
            requested.resolve(strict=True) == resolved and str(resolved) == os.readlink(destination),
            'Reused bundle link or realpath changed')
    actual = _checked(resolved, record['manifestSHA256'], record['expectedNativeSHA256'],
                      Path(archived_runtime), artifacts)
    require(all(record[k] == v for k,v in actual.items()), 'Reused bundle identity changed')
