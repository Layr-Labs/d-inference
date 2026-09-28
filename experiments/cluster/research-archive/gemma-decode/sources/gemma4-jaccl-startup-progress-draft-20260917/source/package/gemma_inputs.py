"""Pinned inputs and create-only evidence; no model payload reads."""
import os
from pathlib import Path
import stat
from binding_common import canonical, fields, integer, parse, pin, require, same
from binding_inputs import snapshot

REMOTE = Path('/Users/developer/DarkbloomDev/gemma4-short-jaccl-progress-20260917')
MODES = ('full', 'stage0', 'stage1')
PRODUCT = 'GemmaShortCorrectnessCheck'
MODEL = '/Users/developer/DarkbloomDev/models/Gemma4-26B'
SOURCE_DRIVER = 'd88473104ae45164e81f4e55a1722015ae1fed81b82677af31eaef7e48c86821'
SOURCE_COMPARATOR = '7edf02ebc9325d616e96e8c708396ba1e307edc549346df5ddf6a53fe38ce1da'
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PAGED = '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'


def write_new(path, raw):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as out:
        out.write(raw); out.flush(); os.fsync(out.fileno())


def write_json(path, value): write_new(path, canonical(value) + b'\n')


class Pins:
    def __init__(self, check=lambda: None): self.saved, self.check = [], check
    def read(self, path, cap, wanted, keep=True):
        path = Path(path); self.check()
        require(path.parent.resolve() == path.parent, 'Input parent contains a link')
        named = path.lstat()
        require(stat.S_ISREG(named.st_mode) and named.st_uid == os.geteuid()
                and named.st_nlink == 1 and named.st_mode & 0o077 == 0, 'Input is not private owned regular single-link')
        value = snapshot(path, cap, keep=keep, empty=True)
        same(value['sha256'], pin(wanted), 'Input SHA256')
        same(value['identity'][:2], (named.st_dev, named.st_ino), 'Input path identity')
        self.saved.append((path, cap, {k:v for k,v in value.items() if k != 'raw'})); self.check()
        return value
    def recheck(self):
        for path, cap, before in self.saved:
            self.check(); named = path.lstat()
            require(path.parent.resolve() == path.parent and named.st_uid == os.geteuid()
                    and named.st_nlink == 1, 'Input owner/path changed')
            after = snapshot(path, cap, keep=False, empty=True)
            same({k:v for k,v in after.items() if k != 'raw'}, before, 'Input changed')
            same(after['identity'][:2], (named.st_dev, named.st_ino), 'Named input changed')


def member_path(name):
    require(type(name) is str and 0 < len(name) <= 256, 'Member name bound')
    p = Path(name)
    require(not p.is_absolute() and str(p) == name and '..' not in p.parts and name != '.', 'Unsafe member')
    return p


def verify_package(root, wanted, pins):
    require(root == REMOTE and root.resolve() == root, 'Wrong canonical installation root')
    mode = root.stat(); require(mode.st_uid == os.geteuid() and mode.st_mode & 0o077 == 0, 'Unsafe package root')
    package = parse(pins.read(root/'package.json', 1_048_576, wanted)['raw'])
    fields(package, 'schema files', 'package'); same(package['schema'], 'gemma_short_package_v1', 'package schema')
    require(type(package['files']) is list and 20 <= len(package['files']) <= 100, 'Package closure count')
    seen, total = set(), 0
    for row in package['files']:
        fields(row, 'path bytes sha256', 'member'); rel = member_path(row['path'])
        require(row['path'] not in seen and rel.parts[0] != 'runs', 'Duplicate or run member')
        size = integer(row['bytes'], 'member bytes', 0, 200_000_000); total += size
        require(total < 400_000_000, 'Package byte bound')
        same(pins.read(root/rel, max(1,size), row['sha256'], keep=False)['size_bytes'], size, 'Member size')
        seen.add(row['path'])
    required = {'run_gemma.py','native_gate.py','gemma_inputs.py','gemma_supervision.py','gemma_result.py',
        'worker_processes.py','worker_contract.py','binding_common.py','binding_inputs.py','mtp_journal.py',
        'target_processes.py','reference_resources.py','stage_checks/__init__.py','stage_checks/common.py',
        'binding.json','expected.json','prompt.ids.json','job-template.json','matrix.json','native-build-reference.json','bundle/'+PRODUCT,
        'bundle/mlx.metallib','bundle/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal',
        'provenance/build-receipt.json','provenance/source-snapshot.json','provenance/dependency-snapshot.json'}
    require(required <= seen, 'Runtime/input closure missing')
    rowmap = {r['path']:r for r in package['files']}
    def json_member(name, cap=4*1024**2): return parse(pins.read(root/name,cap,rowmap[name]['sha256'])['raw'])
    binding = json_member('binding.json')
    fields(binding, 'schema driverManifestSHA256 comparatorManifestSHA256 nativeSHA256 sourceSnapshotSHA256 '
        'dependencySnapshotSHA256 buildReceiptSHA256 expectedSHA256 promptSHA256 residualDType modelDirectory', 'binding')
    same(binding['schema'], 'gemma_short_deployment_binding_v1', 'binding schema')
    same(binding['driverManifestSHA256'], SOURCE_DRIVER, 'driver source'); same(binding['comparatorManifestSHA256'], SOURCE_COMPARATOR, 'comparator source')
    for key, name in [('nativeSHA256','bundle/'+PRODUCT),('sourceSnapshotSHA256','provenance/source-snapshot.json'),
                      ('dependencySnapshotSHA256','provenance/dependency-snapshot.json'),('buildReceiptSHA256','provenance/build-receipt.json'),
                      ('expectedSHA256','expected.json'),('promptSHA256','prompt.ids.json')]:
        same(pin(binding[key]), rowmap[name]['sha256'], key)
    same(rowmap['bundle/mlx.metallib']['sha256'], METALLIB, 'metallib')
    same(rowmap['bundle/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']['sha256'], PAGED, 'paged source')
    build = json_member('provenance/build-receipt.json')
    actual_build=json_member('native-build-reference.json',16384)
    for key in ('nativeSHA256','buildReceiptSHA256','sourceSnapshotSHA256','dependencySnapshotSHA256'):
        same(binding[key],actual_build[key],'Exact root-qualified '+key)
    same(build['status'], 'passed', 'actual native build'); same(build['binary']['sha256'], binding['nativeSHA256'], 'build/native')
    same(build['sourceSnapshotSHA256'], binding['sourceSnapshotSHA256'], 'build source')
    same(build['dependencySnapshotSHA256'], binding['dependencySnapshotSHA256'], 'build dependencies')
    expected = json_member('expected.json',65536)
    same(expected['buildIdentitySHA256'],binding['nativeSHA256'],'expected binary')
    same(expected['promptFileSHA256'],binding['promptSHA256'],'expected prompt')
    require(expected['metadataOnly'] is True and expected['runtimeExecutionAuthorized'] is False
            and expected['actualPayloadLoaded'] is False and expected['cut']==10 and expected['promptCount']==32
            and expected['outputCount']==2, 'Prospective expected contract')
    template = json_member('job-template.json',16384)
    same(template['buildIdentitySHA256'],binding['nativeSHA256'],'job binary')
    same(template['promptFileSHA256'],binding['promptSHA256'],'job prompt')
    same(template['residualDType'],binding['residualDType'],'job dtype')
    same(template['modelDirectory'],binding['modelDirectory'],'job model')
    same(binding['modelDirectory'],MODEL,'Exact agreed model directory')
    for key in ('requestID','membershipEpoch'): same(template[key],expected[key],key)
    same(template['schema'],'gemma4_short_native_check_v1','job schema'); same(template['mode'],'full','template mode')
    same(template['timeoutSeconds'],300,'native lifetime')
    same(template['metadataDirectory'],str(root/'metadata'),'metadata directory')
    same(template['promptFile'],str(root/'prompt.ids.json'),'prompt path')
    same(template['outputDirectory'],str(root/'runs/full-1/sidecars'),'prospective output path')
    require(binding['residualDType'] in ('bfloat16','float16','float32'),'closed dtype')
    require((root/'bundle'/PRODUCT).stat().st_mode & stat.S_IXUSR,'native executable mode')
    return binding, expected, template, rowmap


def job_for(template, mode, attempt):
    require(mode in MODES and type(attempt) is int and 1 <= attempt <= 9, 'Mode/attempt bound')
    job = dict(template); job['mode'] = mode
    job['outputDirectory'] = str(REMOTE/'runs'/f'{mode}-{attempt}'/'sidecars')
    return job
