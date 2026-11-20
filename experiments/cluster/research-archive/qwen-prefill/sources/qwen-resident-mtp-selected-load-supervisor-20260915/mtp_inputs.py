"""Pinned loading-check package and metadata; payload verification stays native-owned."""
import hashlib
import os
from pathlib import Path
import stat
import uuid
from binding_common import canonical, fields, integer, parse, pin, require, same
from binding_inputs import snapshot
from stage_checks.long_profile import ARTIFACT, CONFIGURATION, REQUIRED_ENVIRONMENT
from worker_contract import WorkerSpec, workers

NATIVE = 'acabd7237c8f244db1fe30878f796ec6e4496b43ad82b1df1a0505aea72ea7bf'
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
SOURCE = 'e6b6126fc28258843e3ba7e85ccb12857e005ecde6c8e2f49d95dc6b8334e37d'
BUNDLE = 'bf09d61315aadb2e7688d02fe27e9c294831a68080938d782f676ef4194a75ef'
MANIFEST = '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4'
PAGED = '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'
COORDINATOR = '127.0.0.1:43198'  # Valid metadata only; no socket is opened.

def write_new(path, raw):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as out:
        out.write(raw)
        out.flush()
        os.fsync(out.fileno())


def write_json(path, value):
    write_new(path, canonical(value) + b'\n')


def path(value):
    require(type(value) is str and 0 < len(value) <= 4096 and '\0' not in value,
            'Invalid absolute path')
    result = Path(value)
    require(result.is_absolute() and str(result) == value and '..' not in result.parts
            and not value.startswith('//'), 'Expected normalized absolute path')
    return result


class Pins:
    def __init__(self):
        self.saved = []

    def read(self, filename, cap, wanted=None, keep=True, empty=False):
        value = snapshot(filename, cap, keep=keep, empty=empty)
        require(wanted is None or value['sha256'] == pin(wanted), 'File pin differs: ' + str(filename))
        self.saved.append((Path(filename), cap, empty, {k:v for k,v in value.items() if k != 'raw'}))
        return value

    def recheck(self):
        for filename, cap, empty, before in self.saved:
            after = snapshot(filename, cap, keep=False, empty=empty)
            same({k:v for k,v in after.items() if k != 'raw'}, before, 'Input/source changed: ' + str(filename))


def verify_launcher(directory, wanted, pins):
    value = parse(pins.read(directory / 'manifest.json', 1024**2, wanted)['raw'])
    require(type(value.get('files')) is list and 1 <= len(value['files']) <= 64, 'Launcher member bound')
    seen = set()
    for row in value['files']:
        fields(row, 'path bytes sha256', 'launcher member')
        relative = Path(row['path'])
        require(not relative.is_absolute() and '..' not in relative.parts
                and str(relative) == row['path'] and row['path'] not in seen, 'Launcher member path')
        item = pins.read(directory / relative, 4*1024**2, row['sha256'], keep=False, empty=True)
        require(item['size_bytes'] == integer(row['bytes'], 'launcher bytes', 0, 4*1024**2), 'Launcher size differs')
        seen.add(row['path'])


def validate_job(job):
    fields(job, 'schema run_id deployment model_dir run_dir bundle_sha256 native_sha256 '
           'metallib_sha256 source_manifest_sha256 native_seconds parent_seconds', 'MTP loading job')
    same(job['schema'], 'private_mtp_selected_load_job_v1', 'job schema')
    require(type(job['run_id']) is str and str(uuid.UUID(job['run_id'])) == job['run_id'], 'Canonical fresh run UUID required')
    for name in ('deployment', 'model_dir', 'run_dir'):
        path(job[name])
    run = path(job['run_dir'])
    for name in ('deployment', 'model_dir'):
        other = path(job[name])
        require(run != other and run not in other.parents and other not in run.parents, 'Run overlaps source/input')
    for name, expected in [('bundle_sha256', BUNDLE), ('native_sha256', NATIVE),
                          ('metallib_sha256', METALLIB), ('source_manifest_sha256', SOURCE)]:
        same(pin(job[name]), expected, name)
    same(job['native_seconds'], 300, 'native lifetime')
    same(job['parent_seconds'], 315, 'parent lifetime')
    return job


def verify_inputs(job, pins):
    root = path(job['deployment'])
    require(root.is_dir() and root.resolve() == root, 'Real bundle directory required')
    raw = pins.read(root/'bundle.json', 65536, BUNDLE)['raw']
    bundle = fields(parse(raw), 'schemaVersion scope sourceManifestSHA256 files', 'bundle')
    same(bundle['schemaVersion'], 1, 'bundle version')
    same(bundle['sourceManifestSHA256'], SOURCE, 'bundle source reference')
    require(type(bundle['scope']) is str and 1 <= len(bundle['scope']) <= 512, 'Bundle scope missing')
    expected = {'MTPSelectedLoadCheck': NATIVE, 'mlx.metallib': METALLIB,
                'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal': PAGED}
    require(type(bundle['files']) is list and len(bundle['files']) == 3, 'Exactly three native bundle members required')
    seen = set()
    for row in bundle['files']:
        fields(row, 'path sha256 bytes', 'bundle member')
        name = row['path']
        require(type(name) is str and name in expected and name not in seen, 'Unknown/repeated bundle member')
        same(row['sha256'], expected[name], 'bundle pin')
        item = pins.read(root/name, 256*1024**2, expected[name], keep=False)
        same(item['size_bytes'], integer(row['bytes'], 'bundle size', 1, 256*1024**2), 'bundle size')
        seen.add(name)
    actual = set()
    for directory, dirs, files in os.walk(root, followlinks=False):
        for candidate in [Path(directory)] + [Path(directory)/name for name in dirs+files]:
            mode = candidate.lstat()
            require(mode.st_uid == os.geteuid() and not stat.S_ISLNK(mode.st_mode)
                    and mode.st_mode & 0o022 == 0, 'Unsafe native bundle owner/link/write mode')
            if not stat.S_ISDIR(mode.st_mode):
                require(stat.S_ISREG(mode.st_mode), 'Nonregular bundle member')
                actual.add(candidate.relative_to(root).as_posix())
    same(actual, set(expected) | {'bundle.json'}, 'bundle closure')
    require((root/'MTPSelectedLoadCheck').stat().st_mode & stat.S_IXUSR, 'Native fixture is not executable')
    model = path(job['model_dir'])
    require(model.is_dir() and model.resolve() == model, 'Real model directory required')
    pins.read(model/'config.json', 1024**2, CONFIGURATION)
    pins.read(model/'manifest.json', 4*1024**2, MANIFEST)


def native_environment(run):
    return dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='C', **REQUIRED_ENVIRONMENT,
                JACCL_RANK='1', JACCL_IBV_DEVICES=str(Path(run)/'devices.json'), JACCL_COORDINATOR=COORDINATOR)


def native_spec(job, deadline):
    integer(deadline, 'Swift deadline', 1, 2**64-1)
    args = (str(path(job['deployment'])/'MTPSelectedLoadCheck'), 'load',
        '--model-dir', job['model_dir'], '--rank', '1', '--stage-cut', '4',
        '--membership-epoch', job['run_id'], '--model-id', 'registered_qwen35_9b',
        '--artifact-sha256', ARTIFACT, '--configuration-sha256', CONFIGURATION,
        '--peer0-id', 'load-check-peer0', '--peer0-build-sha256', NATIVE,
        '--peer1-id', 'load-check-peer1', '--peer1-build-sha256', NATIVE,
        '--deadline-uptime-nanoseconds', str(deadline))
    # One locally supervised process; rank1 is the native model-placement field.
    return workers([WorkerSpec(args, native_environment(job['run_dir']), 'solo', None)])[0]
