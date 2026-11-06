"""Pinned small reference bundle and metadata; model payloads stay native-owned."""
import hashlib
import os
from pathlib import Path
import stat
import uuid

from binding_common import canonical, fields, integer, parse, pin, require, same
from binding_inputs import snapshot
from stage_checks.long_profile import REQUIRED_ENVIRONMENT
from reference_profiles import registered_profile
from worker_contract import WorkerSpec, workers

NATIVE = '91c3cf8cdf7bd4ea2ed490ba9e84ab6900eec9261cf6190ea03d2f8c2fe055dc'
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
SOURCE = 'b8b7b2d2fe391b8f7e69dee8e52e84dc5a1667232f3462a4072bdcb532d03222'
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
           'output_count stop_token_ids native_seconds parent_seconds registered_model prompt_count chunk_size', 'reference job')
    require(job['schema'] == 'private_registered_full_generation_reference_job_v1', 'Wrong reference job schema')
    profile = registered_profile(job['registered_model'])
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
    integer(job['stage_cut'], 'cut', 1, profile.layers-1)
    require(job['stage_cut'] in profile.cuts, 'Unsupported cut for registered model')
    integer(job['prompt_count'], 'prompt count', 1, 8192)
    integer(job['chunk_size'], 'chunk size', 1, 512)
    integer(job['output_count'], 'output count', 1, 128)
    require(job['prompt_count'] + job['output_count'] <= 8320, 'Request context exceeds registered profile')
    for name, wanted in [('native_seconds', 300), ('parent_seconds', 315)]:
        same(job[name], wanted, name)
    stops = job['stop_token_ids']
    require(type(stops) is list and len(stops) <= 256, 'Bounded stop token list required')
    for token in stops:
        integer(token, 'stop token', 0, 248319)
    require(stops == sorted(set(stops)), 'Stop token IDs must be sorted and unique')
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
    profile = registered_profile(job['registered_model'])
    root = path(job['deployment'])
    require(root.is_dir() and root.resolve() == root, 'Real bundle directory required')
    raw = pins.read(root / 'bundle.json', 65536, job['bundle_sha256'])['raw']
    bundle = fields(parse(raw), 'schema files buildReceiptSHA256 sourceSnapshotSHA256 dependencySnapshotSHA256 acceptedManifestSHA256 nativeMTPQualified correctnessOnly servingEnabled physicalExecuted', 'bundle')
    same(bundle, {'acceptedManifestSHA256': 'aa3b66fce361d1086bfaa979679ce25f844f6630630336805e3e1ea17460bbd4', 'buildReceiptSHA256': 'be40029f4e09c0899b8a3d3db2c770f56f7147c5c64d60fef98cfd135a1c8239', 'correctnessOnly': True, 'dependencySnapshotSHA256': 'd63cf7457244c7b67b48f3aa7ff3ea1b421dc0239717e2a7eb8f05411cb12707', 'files': [{'bytes': 44731264, 'path': 'cluster-inference', 'sha256': '91c3cf8cdf7bd4ea2ed490ba9e84ab6900eec9261cf6190ea03d2f8c2fe055dc'}, {'bytes': 45366008, 'path': 'darkbloom-cluster-worker', 'sha256': '7787dad579c454176ac902336ce764efc215db087e7e34267a0de7e8e4449435'}, {'bytes': 182425984, 'path': 'mlx.metallib', 'sha256': '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'}, {'bytes': 24804, 'path': 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal', 'sha256': '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'}], 'nativeMTPQualified': False, 'physicalExecuted': False, 'schema': 'qwen_mtp_accepted_native_bundle_v1', 'servingEnabled': False, 'sourceSnapshotSHA256': 'b8b7b2d2fe391b8f7e69dee8e52e84dc5a1667232f3462a4072bdcb532d03222'}, 'Exact actual same-source bundle metadata')
    require(bundle['sourceSnapshotSHA256'] == job['source_manifest_sha256'], 'Bundle source reference differs')
    expected = {'cluster-inference': NATIVE, 'darkbloom-cluster-worker': '7787dad579c454176ac902336ce764efc215db087e7e34267a0de7e8e4449435', 'mlx.metallib': METALLIB,
                'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal': PAGED}
    require(type(bundle['files']) is list and len(bundle['files']) == 4, 'Exactly four same-source bundle members required')
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
    pins.read(model/'config.json', 1024**2, profile.configuration)
    pins.read(model/'manifest.json', 4*1024**2, profile.manifest)
    prompt = pins.read(path(job['prompt_file']), 65536, job['prompt_sha256'])['raw']
    tokens = parse(prompt)
    require(type(tokens) is list and len(tokens) == job['prompt_count'], 'Prompt count differs from declared request')
    for token in tokens:
        integer(token, 'prompt token', 0, 248319)
    return prompt, tokens


def native_spec(job):
    run = path(job['run_dir'])
    argv = (str(path(job['deployment'])/'cluster-inference'), '--mode', 'qwen-registered-full-generation-reference',
            '--model-dir', job['model_dir'], '--tokens-file', str(run/'prompt.json'),
            '--tokens-sha256', job['prompt_sha256'], '--request-id', job['request_id'],
            '--stage-cut', str(job['stage_cut']), '--output-count', str(job['output_count']),
            '--stop-token-ids', canonical(job['stop_token_ids']).decode(),
            '--registered-dense-profile', job['registered_model'], '--prompt-count', str(job['prompt_count']),
            '--chunk-size', str(job['chunk_size']), '--timeout-seconds', '300')
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='C', **REQUIRED_ENVIRONMENT)
    return workers([WorkerSpec(argv, env, 'solo', None)])[0]
