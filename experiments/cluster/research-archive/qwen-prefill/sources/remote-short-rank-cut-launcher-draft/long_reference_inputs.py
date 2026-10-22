"""Pinned short natural prefix/teacher provenance; no import-time file reads."""
import hashlib
import json
from pathlib import Path
import re
from prefill_compute_archive import digest

ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIGURATION = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
PROMPT_SHA256 = '667b2e8232e3fc941469be79c3a178469b7d90c23d6f3ef1de4bd8bd87a813fc'
TEACHER_SHA256 = 'aad3b6387a197e052f32d75bd3d0aead834da80e577279665e04966e81c27fbc'
ORIGIN_SHA256 = '0afffd9b1863f785f4f3880f71c21305177f36cb825e29e506983ff0f745cfc1'
PREFIX96_SHA256 = '36b9329c650a57fb8c5a30c13aeafc8155047d14527f62d824c3e7e104a968d2'
SOURCE_TEXT_SHA256 = '6a76e63af205e75c3e702a7e85be76d1d0575133d9deffd171d6de6e7b3db920'
VOCABULARY, PROMPT_COUNT, CHUNK_SIZE = 248320, 65, 32
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


def parse_tokens(raw, count):
    require(0 < len(raw) <= MAX_PROMPT_BYTES, 'Token input exceeds 64 KiB')
    def reject(value):
        raise ValueError('Tokens admit only strict JSON integers')
    def integer(value):
        require(value != '-0', 'Tokens reject negative-zero integer spelling')
        return int(value)
    values = json.loads(raw, parse_float=reject, parse_constant=reject, parse_int=integer)
    require(type(values) is list and len(values) == count
            and all(type(x) is int and 0 <= x < VOCABULARY for x in values),
            'Wrong fixed token count/type/vocabulary')
    return values


def archive_inputs(prompt_file, prompt_sha256, teacher_file, teacher_sha256,
                   origin_file, origin_sha256, prefix_file, text_file, output):
    require((prompt_sha256, teacher_sha256, origin_sha256) == (PROMPT_SHA256, TEACHER_SHA256, ORIGIN_SHA256),
            'Only the registered short prompt/teacher/origin pins are admitted')
    sources = [('prompt.json', prompt_file, prompt_sha256, MAX_PROMPT_BYTES),
               ('teacher.json', teacher_file, teacher_sha256, MAX_PROMPT_BYTES),
               ('origin-receipt.json', origin_file, origin_sha256, MAX_ORIGIN_BYTES),
               ('origin-prompt-96.json', prefix_file, PREFIX96_SHA256, MAX_PROMPT_BYTES),
               ('source-text.txt', text_file, SOURCE_TEXT_SHA256, MAX_PROMPT_BYTES)]
    retained = {name: read_pinned(path, pin, cap) for name, path, pin, cap in sources}
    prompt, teacher = parse_tokens(retained['prompt.json'], 65), parse_tokens(retained['teacher.json'], 3)
    prefix = parse_tokens(retained['origin-prompt-96.json'], 96)
    origin = json.loads(retained['origin-receipt.json'])
    require(type(origin) is dict and type(origin.get('tokenization')) is dict
            and type(origin.get('native_calls')) is list, 'Wrong pinned origin structure')
    tokenization = origin['tokenization']
    require(type(tokenization.get('prompt_ids')) is list and prompt == tokenization['prompt_ids'][:65]
            and prompt == prefix[:65] and tokenization.get('source_text_sha256') == SOURCE_TEXT_SHA256
            and teacher == [4087, 13, 271] and origin.get('baseline_teacher_tokens') == teacher,
            'Natural-text prefix/teacher history differs from pinned origin')
    calls = [c for c in origin['native_calls'] if type(c) is dict and c.get('name') == 'cbv2-native']
    require(len(calls) == 1 and calls[0].get('status') == 'validated'
            and type(calls[0].get('exit_code')) is int and calls[0]['exit_code'] == 0
            and calls[0].get('rank_evidence_sha256', {}).get('rank-0/teacher.json') == teacher_sha256,
            'Named original CBv2 teacher evidence differs')
    directory = output / 'inputs'; directory.mkdir(mode=0o700)
    for name, path, pin, cap in sources:
        with (directory / name).open('xb') as stream:
            stream.write(retained[name])
        (directory / name).chmod(0o400)
        require(read_pinned(path, pin, cap) == retained[name], 'Pinned input changed during archive')
    logical = lambda values: hashlib.sha256(json.dumps(values, separators=(',', ':')).encode()).hexdigest()
    return dict(prompt=prompt, teacher=teacher, prompt_file_sha256=prompt_sha256,
        teacher_file_sha256=teacher_sha256, prompt_token_ids_sha256=logical(prompt),
        teacher_token_ids_sha256=logical(teacher), token_ids_hash_encoding='compact_json_integer_array_utf8',
        prompt_origin_file_sha256=origin_sha256,
        prompt_origin_schema_audited_by_launcher=True, named_teacher_call='cbv2-native',
        raw_prompt_reencoded=False, raw_teacher_reencoded=False,
        files=[dict(path=p.relative_to(output).as_posix(), sha256=digest(p), size_bytes=p.stat().st_size)
               for p in sorted(directory.iterdir())])
