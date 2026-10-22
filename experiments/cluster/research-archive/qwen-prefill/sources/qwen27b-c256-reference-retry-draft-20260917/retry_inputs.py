"""One explicit retry binding; no alternate workload, trust or resource policy."""
from pathlib import Path
import hashlib
import json
import os
import stat

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
DRAFT = ROOT / 'resident-generation-phase-memory-draft-20260917'
EXPERIMENT = DRAFT / 'Experiment'
OLD = EXPERIMENT / 'reference'
PREPARED = BASE / 'prepared'
INPUTS = PREPARED / 'inputs'
REFERENCE = PREPARED / 'reference'
OLD_LAUNCH = '/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/supervisor-phase-memory-c256-20260917'
NEW_LAUNCH = '/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/supervisor-phase-memory-c256-retry2-20260917'
OLD_RUN = '/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/runs/phase-memory-c256-1'
NEW_RUN = '/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/runs/phase-memory-c256-2'


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path, cap=4*1024**2):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'Canonical source path required')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= cap, 'Small regular source/input required')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            raw = stream.read(cap+1)
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(identity(before) == identity(after) == identity(path.lstat()) and len(raw) == before.st_size,
                'Source/input changed during read')
        return raw
    finally:
        os.close(fd)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)+'\n').encode()


def pin(path):
    raw = read(path)
    return dict(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def verify_map(folder, files):
    require(type(files) is dict and 1 <= len(files) <= 120, 'Source manifest count bound')
    for name, expected in files.items():
        relative = Path(name)
        require(not relative.is_absolute() and '..' not in relative.parts and str(relative) == name,
                'Unsafe source member')
        require(pin(folder / relative) == expected, 'Source/input pin changed: '+name)


def verify_source():
    verify_map(BASE, json.loads(read(BASE/'manifest.json'))['files'])
    for row in json.loads(read(BASE/'parent-pins.json'))['files']:
        require(pin(Path(row['path'])) == {k: row[k] for k in ('bytes', 'sha256')}, 'Parent source/evidence changed')
    verify_map(OLD, json.loads(read(OLD/'manifest.json'))['files'])


def expected_packet():
    old = json.loads(read(EXPERIMENT/'inputs-1/reference-job.json'))
    require(old['prompt_file'] == OLD_LAUNCH+'/prompt.ids.json' and old['run_dir'] == OLD_RUN,
            'Original reference path binding changed')
    new = dict(old, prompt_file=NEW_LAUNCH+'/prompt.ids.json', run_dir=NEW_RUN)
    require(read(BASE/'reference-job.json') == canonical(new), 'Retry job changed beyond two explicit paths')
    require((new['request_id'], new['registered_model'], new['stage_cut'], new['prompt_count'], new['chunk_size'],
             new['output_count'], new['stop_token_ids'], new['native_seconds'], new['parent_seconds'])
            == ('72a2b195-bb12-4da5-ae3a-986352fc2dc4','registered_qwen38_27b',16,8192,256,128,[],300,315),
            'Retry workload differs')
    return new, json.loads(read(EXPERIMENT/'inputs-1/request.json'))


def verify_prepared():
    verify_source()
    verify_map(PREPARED, json.loads(read(PREPARED/'manifest.json'))['files'])
    job, request = expected_packet()
    require(read(INPUTS/'reference-job.json') == canonical(job)
            and read(REFERENCE/'package/example-job.json') == canonical(job), 'Prepared retry job changed')
    require(read(INPUTS/'request.json') == canonical(request), 'Prepared request changed')
    require(read(INPUTS/'prompt.ids.json') == read(EXPERIMENT/'inputs-1/prompt.ids.json')
            == read(REFERENCE/'package/prompt.ids.json'), 'Prepared prompt changed')
    return job, request
