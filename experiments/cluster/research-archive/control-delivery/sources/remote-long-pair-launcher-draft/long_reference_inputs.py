"""Pinned raw prompt and opaque tokenization provenance; no model reads."""
import hashlib
import json
from pathlib import Path
import re
from prefill_compute_archive import digest

ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIGURATION = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
PROFILE = 'long_prefill_8k_v1'
PROFILE_SHA256 = '2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b'
VOCABULARY, PROMPT_COUNT, CHUNK_SIZE = 248320, 8192, 512
MAX_PROMPT_BYTES, MAX_ORIGIN_BYTES = 65536, 2 * 1024**2


def require(value, message):
    if not value:
        raise ValueError(message)


def is_sha256(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None


def read_pinned(path, expected, maximum):
    path = Path(path)
    require(is_sha256(expected), 'Explicit lowercase SHA256 pin required')
    require(path.is_file() and not path.is_symlink(), 'Input must be a regular non-symlink file')
    with path.open('rb') as stream:
        raw = stream.read(maximum + 1)
    require(0 < len(raw) <= maximum and hashlib.sha256(raw).hexdigest() == expected,
            'Bounded input or exact raw-file SHA256 differs')
    return raw


def parse_prompt(raw):
    require(0 < len(raw) <= MAX_PROMPT_BYTES, 'Prompt exceeds 64 KiB')
    def reject(value):
        raise ValueError('Prompt admits only strict JSON integers')
    def integer(value):
        require(value != '-0', 'Prompt rejects negative-zero integer spelling')
        return int(value)
    values = json.loads(raw, parse_float=reject, parse_constant=reject, parse_int=integer)
    require(type(values) is list and len(values) == PROMPT_COUNT
            and all(type(x) is int and 0 <= x < VOCABULARY for x in values),
            'Prompt must contain exactly 8192 in-vocabulary integers')
    return values


def archive_inputs(prompt_file, prompt_sha256, origin_file, origin_sha256, output):
    raw = read_pinned(prompt_file, prompt_sha256, MAX_PROMPT_BYTES)
    prompt = parse_prompt(raw)
    # The caller independently audited tokenization. Preserve the origin bytes
    # and explicit pin without inventing or trusting a provenance JSON schema.
    origin = read_pinned(origin_file, origin_sha256, MAX_ORIGIN_BYTES)
    directory = output / 'inputs'
    directory.mkdir(mode=0o700)
    for name, content in [('prompt.json', raw), ('prompt-origin.json', origin)]:
        target = directory / name
        with target.open('xb') as stream:
            stream.write(content)
        target.chmod(0o400)
    require(read_pinned(prompt_file, prompt_sha256, MAX_PROMPT_BYTES) == raw
            and read_pinned(origin_file, origin_sha256, MAX_ORIGIN_BYTES) == origin,
            'Pinned input changed during archive')
    return dict(prompt=prompt, teacher=[], prompt_file_sha256=prompt_sha256,
                prompt_token_ids_sha256=hashlib.sha256(','.join(map(str, prompt)).encode()).hexdigest(),
                prompt_origin_file_sha256=origin_sha256, prompt_origin_schema_audited_by_launcher=False,
                raw_prompt_reencoded=False,
                files=[dict(path=p.relative_to(output).as_posix(), sha256=digest(p), size_bytes=p.stat().st_size)
                       for p in sorted(directory.iterdir())])
