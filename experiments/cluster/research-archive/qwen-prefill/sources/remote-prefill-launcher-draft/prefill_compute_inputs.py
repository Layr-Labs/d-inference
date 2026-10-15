"""Fixed approved artifact and retained65/32/1 input provenance; no import-time reads."""

import hashlib
import json
from pathlib import Path
import shutil

from prefill_compute_archive import digest, write_json

ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIGURATION = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
ORIGIN_RECEIPT = '0afffd9b1863f785f4f3880f71c21305177f36cb825e29e506983ff0f745cfc1'
EXPECTED_INVENTORY = 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99'
VOCABULARY = 248320


def read_tokens(path, count):
    if path.stat().st_size > 65536:
        raise ValueError('Token file exceeds64KiB')
    values = json.loads(path.read_text())
    if not isinstance(values, list) or len(values) != count or any(type(x) is not int or not 0 <= x < VOCABULARY for x in values):
        raise ValueError('Fixed token history has invalid count/type/vocabulary')
    return values


def archive_inputs(origin, inventory, output):
    if digest(origin / 'receipt.json') != ORIGIN_RECEIPT or digest(inventory) != EXPECTED_INVENTORY:
        raise ValueError('Input origin or independent inventory pin differs')
    original = json.loads((origin / 'receipt.json').read_text())
    prompt = read_tokens(origin / 'prompt-65.json', 65)
    if prompt != original['tokenization']['prompt_ids'][:65] or digest(origin / 'source-text.txt') != original['tokenization']['source_text_sha256']:
        raise ValueError('Token IDs/source text do not match the pinned origin receipt')
    if prompt != read_tokens(origin / 'prompt-96.json', 96)[:65]:
        raise ValueError('Prompt differs from the recorded natural-text prefix')
    directory = output / 'inputs'
    directory.mkdir(mode=0o700)
    for name, source in [('origin-receipt.json', origin / 'receipt.json'),
                         ('origin-prompt-65.json', origin / 'prompt-65.json'),
                         ('origin-prompt-96.json', origin / 'prompt-96.json'),
                         ('source-text.txt', origin / 'source-text.txt'),
                         ('expected-inventory.json', inventory)]:
        before = digest(source)
        shutil.copyfile(source, directory / name)
        if digest(source) != before or digest(directory / name) != before:
            raise ValueError('Input changed during snapshot')
        (directory / name).chmod(0o400)
    write_json(directory / 'prompt.json', prompt)
    return dict(prompt=prompt, teacher=[],
                files=[dict(path=p.relative_to(output).as_posix(), sha256=digest(p), size_bytes=p.stat().st_size)
                       for p in sorted(directory.iterdir())])


def expected_frames():
    return [dict(sequence=i, phase='prefill' if i < 3 else 'decode', tokenOffset=offset,
                 tokenCount=count, finalPromptChunk=i == 2)
            for i, (offset, count) in enumerate([(0,32),(32,32),(64,1)])]


def request_fingerprint(request_id):
    import uuid
    text = f'qwen-stage-request-v1|{str(uuid.UUID(request_id))}|65|32|1'
    return hashlib.sha256(text.encode()).hexdigest()


def recorded_fingerprint(request_id,prompt):
    text='\n'.join(['qwen-layer-stage-recorded-request-v1',request_fingerprint(request_id),
        f'vocabulary={VOCABULARY}','prompt='+','.join(map(str,prompt)),'teacher='])
    return hashlib.sha256(text.encode()).hexdigest()
