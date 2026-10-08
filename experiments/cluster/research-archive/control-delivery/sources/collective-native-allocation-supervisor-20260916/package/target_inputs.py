"""Bounded immutable package verification and durable private evidence files."""
import os
from pathlib import Path
import stat

from binding_common import canonical, fields, integer, parse, pin, require, same
from binding_inputs import snapshot
from target_contract import ARTIFACT, BUNDLE, JOBS, METALLIB, PAGED, SOURCE
from allocation_result import CASES


def write_new(path, raw):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as out:
        out.write(raw)
        out.flush()
        os.fsync(out.fileno())


def write_json(path, value):
    write_new(path, canonical(value) + b'\n')


class Pins:
    def __init__(self, check=lambda: None):
        self.saved, self.check = [], check

    def read(self, filename, cap, wanted, keep=True):
        self.check()
        filename = Path(filename)
        require(filename.parent.resolve() == filename.parent, 'Input parent contains a link')
        named = filename.lstat()
        require(stat.S_ISREG(named.st_mode) and named.st_uid == os.geteuid()
                and named.st_nlink == 1 and named.st_mode & 0o077 == 0,
                'Input must be a private owned regular file with one link')
        value = snapshot(filename, cap, keep=keep, empty=True)
        require(value['sha256'] == pin(wanted), 'File pin differs: ' + str(filename))
        require(value['identity'][:2] == (named.st_dev, named.st_ino), 'Input changed before snapshot')
        self.saved.append((filename, cap, {k:v for k,v in value.items() if k != 'raw'}))
        self.check()
        return value

    def recheck(self):
        for filename, cap, before in self.saved:
            self.check()
            require(filename.parent.resolve() == filename.parent, 'Input parent changed')
            after = snapshot(filename, cap, keep=False, empty=True)
            named = filename.lstat()
            require(named.st_uid == os.geteuid() and named.st_nlink == 1
                    and after['identity'][:2] == (named.st_dev, named.st_ino), 'Input owner/path changed')
            same({k:v for k,v in after.items() if k != 'raw'}, before, 'Input/source changed: ' + str(filename))


def verify_package(root, wanted, pins, fixture):
    require(ARTIFACT['status'] == 'bound_passed_build', 'Native build has not been bound')
    require(fixture in JOBS, 'Unknown native fixture')
    root = Path(root)
    require(root.is_dir() and root.resolve() == root, 'Package path contains a link')
    mode = root.stat()
    require(mode.st_uid == os.geteuid() and mode.st_mode & 0o077 == 0, 'Package must be private and owned')
    package = parse(pins.read(root/'package.json', 1024**2, wanted)['raw'])
    fields(package, 'schema files', 'package')
    same(package['schema'], 'collective_allocation_supervisor_package_v1', 'package schema')
    rows = package['files']
    require(type(rows) is list and 16 <= len(rows) <= 64, 'Package member count differs')
    seen, total = set(), 0
    for row in rows:
        fields(row, 'path bytes sha256', 'package member')
        name = row['path']
        require(type(name) is str and len(name) <= 256, 'Package member name bound')
        relative = Path(name)
        require(not relative.is_absolute() and '..' not in relative.parts and str(relative) == name
                and name not in seen and relative.parts[0] != 'runs', 'Unsafe package member')
        size = integer(row['bytes'], 'package bytes', 0, 200_000_000)
        total += size
        require(total < 400_000_000, 'Package total bound')
        item = pins.read(root/relative, max(size, 1), row['sha256'], keep=False)
        same(item['size_bytes'], size, 'Package member size')
        seen.add(name)
    required = {'run_target.py', 'target_supervision.py', 'target_contract.py', 'target_inputs.py',
        'target_processes.py', 'worker_processes.py', 'worker_contract.py', 'reference_resources.py',
        'binding_common.py', 'binding_inputs.py', 'mtp_journal.py',
        'stage_checks/__init__.py', 'stage_checks/common.py', 'bundle/bundle.json',
        'allocation_result.py', 'PROBE-SCHEDULE.json', 'native-binding.json',
        'native-contract/cases.stdout'}
    require(required <= seen, 'Package runtime closure missing')
    bundle = parse(pins.read(root/'bundle/bundle.json', 16384, BUNDLE)['raw'])
    same(bundle['schema'], 'collective_allocation_native_bundle_v1', 'native bundle schema')
    same(bundle['buildReceiptSHA256'], ARTIFACT['buildReceiptSHA256'], 'native build receipt')
    same(bundle['nativeExecuted'], False, 'packager did not execute native cases')
    same(bundle['remoteExecuted'], False, 'packager did not execute remotely')
    expected = {'CollectiveAllocationCheck': ARTIFACT['nativeSHA256'],
        'mlx.metallib': METALLIB, 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal': PAGED,
        'source-identity.json': ARTIFACT['sourceIdentitySHA256']}
    require(type(bundle['files']) is list and len(bundle['files']) == 4, 'Native resource closure')
    actual = set()
    for row in bundle['files']:
        fields(row, 'path bytes sha256', 'native resource')
        require(row['path'] in expected and row['path'] not in actual, 'Native resource name')
        same(row['sha256'], expected[row['path']], 'Native resource pin')
        actual.add(row['path'])
        require(any(x == dict(path='bundle/'+row['path'], bytes=row['bytes'], sha256=row['sha256'])
                    for x in rows), 'Native resource differs from package member')
    identity = parse(pins.read(root/'bundle/source-identity.json', 1024**2, ARTIFACT['sourceIdentitySHA256'])['raw'])
    same(identity['sourceSnapshotSHA256'], SOURCE, 'native source snapshot')
    same(identity['buildReceiptSHA256'], ARTIFACT['buildReceiptSHA256'], 'source build binding')
    same(identity['nativeExecuted'], False, 'source identity only')
    same(identity['resourceProfileQualified'], False, 'no resource profile inferred')
    catalog = parse(pins.read(root/'native-contract/cases.stdout', 65_537, identity['catalog']['stdoutSHA256'])['raw'])
    expected_cases = [dict(id=row['id'], byteCounts=[g['bytes'] for g in row['geometries']],
        primingByteCounts=[g['bytes'] for g in row['priming']], rounds=row['rounds'], failure=row['failure'])
        for row in CASES.values()]
    same(catalog, expected_cases, 'actual compiled 35-case catalog')
    require((root/'bundle/CollectiveAllocationCheck').stat().st_mode & stat.S_IXUSR, 'Native entry is not executable')
    return dict(packageSHA256=wanted, fixture=fixture, nativeSHA256=ARTIFACT['nativeSHA256'], sourceSnapshotSHA256=SOURCE,
        bundleSHA256=BUNDLE, metallibSHA256=METALLIB, packageMembers=len(rows), packageBytes=total,
        compiledCatalogSHA256=identity['catalog']['stdoutSHA256'], resourceProfileQualified=False)
