"""Pinned small reference bundle and metadata; model payloads stay native-owned."""
import hashlib
import os
from pathlib import Path
import stat
import uuid

from binding_common import canonical, fields, integer, parse, pin, require, same
from binding_inputs import snapshot
from stage_checks.long_profile import ARTIFACT, CONFIGURATION, REQUIRED_ENVIRONMENT
from worker_contract import WorkerSpec, workers

NATIVE = '9cc39c45793131157025bfba028fcd1876e1764b109d1e15e3c39926a28757e7'
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
SOURCE = '12a52419acbd49da105dd817771c692daef20352c6ae2ba8c64806d3e637d122'
MANIFEST = '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4'
PAGED = '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'


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


def validate_job(job):
    fields(job, 'schema request_id deployment model_dir prompt_file prompt_sha256 run_dir '
           'bundle_sha256 native_sha256 metallib_sha256 source_manifest_sha256 stage_cut '
           'output_count stop_token_ids native_seconds parent_seconds', 'reference job')
    require(job['schema'] == 'private_full_generation_reference_job_v1', 'Wrong reference job schema')
    require(type(job['request_id']) is str and str(uuid.UUID(job['request_id'])) == job['request_id'],
            'Canonical request UUID required')
    for name in ('deployment', 'model_dir', 'prompt_file', 'run_dir'):
        path(job[name])
    run = path(job['run_dir'])
    for name in ('deployment', 'model_dir', 'prompt_file'):
        other = path(job[name])
        require(run != other and run not in other.parents and other not in run.parents,
                'Run directory overlaps source/input')
    for name in ('bundle_sha256', 'native_sha256', 'metallib_sha256', 'source_manifest_sha256', 'prompt_sha256'):
        pin(job[name])
    require(job['native_sha256'] == NATIVE and job['metallib_sha256'] == METALLIB
            and job['source_manifest_sha256'] == SOURCE, 'Job differs from the frozen reference build')
    integer(job['stage_cut'], 'cut', 4, 16)
    require(job['stage_cut'] in (4, 8, 12, 16), 'Unsupported cut')
    for name, wanted in [('output_count', 128), ('native_seconds', 300), ('parent_seconds', 315)]:
        same(job[name], wanted, name)
    same(job['stop_token_ids'], [], 'empty stops')
    return job


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


def verify_inputs(job, pins):
    root = path(job['deployment'])
    require(root.is_dir() and root.resolve() == root, 'Real bundle directory required')
    raw = pins.read(root / 'bundle.json', 65536, job['bundle_sha256'])['raw']
    bundle = fields(parse(raw), 'schemaVersion scope sourceManifestSHA256 files', 'bundle')
    same(bundle['schemaVersion'], 1, 'bundle version')
    require(type(bundle['scope']) is str and 1 <= len(bundle['scope']) <= 512, 'Bundle scope missing')
    require(bundle['sourceManifestSHA256'] == job['source_manifest_sha256'], 'Bundle source reference differs')
    expected = {'cluster-inference': NATIVE, 'mlx.metallib': METALLIB,
                'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal': PAGED}
    require(type(bundle['files']) is list and len(bundle['files']) == 3, 'Exactly three bundle members required')
    seen = set()
    for row in bundle['files']:
        fields(row, 'path sha256 bytes', 'bundle member')
        name = row['path']
        require(type(name) is str and name in expected and name not in seen, 'Unknown or repeated bundle member')
        require(row['sha256'] == expected[name], 'Bundle member build pin differs')
        item = pins.read(root / name, 256*1024**2, expected[name], keep=False)
        require(item['size_bytes'] == integer(row['bytes'], 'bundle bytes', 1, 256*1024**2), 'Bundle size differs')
        seen.add(name)
    actual = set()
    for directory, dirs, files in os.walk(root, followlinks=False):
        for candidate in [Path(directory)] + [Path(directory)/n for n in dirs+files]:
            status = candidate.lstat()
            require(status.st_uid == os.geteuid() and not stat.S_ISLNK(status.st_mode)
                    and status.st_mode & 0o022 == 0, 'Bundle ownership/link/write mode differs')
            if not stat.S_ISDIR(status.st_mode):
                require(stat.S_ISREG(status.st_mode), 'Non-regular bundle member')
                actual.add(candidate.relative_to(root).as_posix())
    require(actual == set(expected) | {'bundle.json'}, 'Bundle tree differs')
    require((root/'cluster-inference').stat().st_mode & stat.S_IXUSR, 'Native is not executable')
    model = path(job['model_dir'])
    require(model.is_dir() and model.resolve() == model, 'Real model directory required')
    pins.read(model/'config.json', 1024**2, CONFIGURATION)
    pins.read(model/'manifest.json', 4*1024**2, MANIFEST)
    prompt = pins.read(path(job['prompt_file']), 65536, job['prompt_sha256'])['raw']
    tokens = parse(prompt)
    require(type(tokens) is list and len(tokens) == 8192, 'Expected exactly 8192 prompt IDs')
    for token in tokens:
        integer(token, 'prompt token', 0, 248319)
    return prompt, tokens


def native_spec(job):
    run = path(job['run_dir'])
    argv = (str(path(job['deployment'])/'cluster-inference'), '--mode', 'qwen-full-generation-reference',
            '--model-dir', job['model_dir'], '--tokens-file', str(run/'prompt.json'),
            '--tokens-sha256', job['prompt_sha256'], '--request-id', job['request_id'],
            '--stage-cut', str(job['stage_cut']), '--output-count', '128', '--stop-token-ids', '[]',
            '--timeout-seconds', '300')
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='C', **REQUIRED_ENVIRONMENT)
    return workers([WorkerSpec(argv, env, 'solo', None)])[0]
