"""Admission and evidence bounds for explicit one-shot real local correctness.

Metadata admission does not replace full artifact hashing in each rank worker,
or native descriptor/storage checks before selected tensor materialization.
"""

import hashlib
import json
import math
from pathlib import Path
import re


MAX_MANIFEST_BYTES = 8 * 1024**3
MAX_TEXT_BYTES = 6 * 1024**3
MAX_RANK_BYTES = 4 * 1024**3
MAX_PAIR_BYTES = 8 * 1024**3
MAX_HOST_TENSOR_BYTES = 512 * 1024**2
MAX_CAPTURE_VALUES = 1_048_576
MAX_CONFIG_JSON_BYTES = 1024**2
MAX_MANIFEST_JSON_BYTES = 4 * 1024**2
MAX_CAPTURE_JSON_BYTES = 32 * 1024**2


def require(condition, message):
    if not condition:
        raise ValueError('local_correctness: ' + message)


def enabled(spec):
    value = spec.get('local_correctness', False)
    require(type(value) is bool, 'must be a Boolean')
    return value


def json_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f'duplicate JSON field {key}')
        result[key] = value
    return result


def read_json(path, max_bytes=MAX_CONFIG_JSON_BYTES):
    try:
        with path.open('rb') as stream:
            data = stream.read(max_bytes + 1)
        require(len(data) <= max_bytes, f'{path.name} exceeds the {max_bytes}-byte JSON limit')
        return data, json.loads(data, object_pairs_hook=json_object,
                               parse_constant=lambda value: require(False, 'nonfinite JSON value'))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f'local_correctness: cannot read valid JSON from {path.name}') from error


def validate_spec(spec):
    """Check the already normalized workload, then only small local metadata."""
    if not enabled(spec):
        require(spec['backend'] != 'loopback-test' or spec['workload'].get('synthetic') is True,
                'real loopback requires explicit opt-in')
        return None
    work, ranks = spec['workload'], spec['ranks']
    require(spec['backend'] == 'loopback-test' and len(ranks) == 2
            and all(r['location'] == 'local' and not r.get('host') for r in ranks),
            'requires exactly two local loopback-test ranks')
    require(work.get('synthetic', False) is False, 'requires real dense Qwen weights')
    require(spec.get('capture_logits') is True, 'requires complete logits capture')
    prompt = work.get('prompt_ids')
    require(isinstance(prompt, list) and 1 <= len(prompt) <= 128
            and work['prompt_tokens'] == len(prompt)
            and all(type(token) is int and token >= 0 for token in prompt),
            'requires 1..128 actual prompt IDs')
    require(type(work['chunk_size']) is int and 1 <= work['chunk_size'] <= 32,
            'chunk_size must be 1..32')
    require(type(work['decode_tokens']) is int and 1 <= work['decode_tokens'] <= 4,
            'decode_tokens must be 1..4')
    require(type(work['repeats']) is int and work['repeats'] == 1
            and type(work['warmups']) is int and work['warmups'] == 0,
            'requires one repetition and zero warmups')
    require(type(spec['timeout_seconds']) is int and 1 <= spec['timeout_seconds'] <= 180,
            'timeout_seconds must be 1..180')
    teacher = work.get('teacher_tokens')
    require(work['decode_tokens'] == 1 or teacher is not None, 'multiple outputs require teacher tokens')
    if teacher is not None:
        require(isinstance(teacher, list) and len(teacher) == work['decode_tokens'] - 1
                and all(type(token) is int and token >= 0 for token in teacher),
                'teacher tokens must contain exactly output count minus one IDs')
    require(work['ffn_branch_precision'] == 'native', 'requires dense Qwen FFN branch policy')
    expected = spec.get('artifact_aggregate_sha256')
    require(isinstance(expected, str) and re.fullmatch('[0-9a-f]{64}', expected) is not None,
            'requires the expected registered aggregate SHA-256')
    identities = []
    for rank in ranks:
        directory = Path(rank['model_directory'])
        data, config = read_json(directory / 'config.json')
        require(isinstance(config, dict) and config.get('model_type') in ('qwen3_5', 'qwen3_5_text'),
                'requires the dense Qwen adapter')
        text = config.get('text_config', config)
        require(isinstance(text, dict) and text.get('model_type', 'qwen3_5_text') == 'qwen3_5_text'
                and type(text.get('num_experts', 0)) is int and text.get('num_experts', 0) == 0,
                'requires a dense Qwen text configuration')
        vocabulary, context = text.get('vocab_size'), text.get('max_position_embeddings')
        require(type(vocabulary) is int and 4 <= vocabulary <= (2**31 - 1) // 2,
                'requires a valid vocabulary size')
        require(type(context) is int and context > 0
                and len(prompt) + work['decode_tokens'] <= context,
                'prompt plus outputs exceed the declared model context')
        require(work['decode_tokens'] * vocabulary <= MAX_CAPTURE_VALUES,
                'output count times vocabulary exceeds the capture limit')
        require(all(token < vocabulary for token in prompt + (teacher or [])),
                'prompt or teacher ID exceeds the vocabulary')
        digest = hashlib.sha256(data).hexdigest()
        _, manifest = read_json(directory / 'manifest.json', MAX_MANIFEST_JSON_BYTES)
        require(isinstance(manifest, dict) and type(manifest.get('schema_version')) is int
                and manifest['schema_version'] == 1 and manifest.get('aggregate_sha256') == expected,
                'manifest must match the requested aggregate')
        total = manifest.get('total_size_bytes')
        require(type(total) is int and 0 < total <= MAX_MANIFEST_BYTES,
                'manifest payload exceeds 8 GiB or is invalid')
        entries = manifest.get('files')
        require(isinstance(entries, list) and all(isinstance(entry, dict) for entry in entries),
                'manifest files must be objects')
        configurations = [entry for entry in entries if entry.get('path') == 'config.json']
        require(len(configurations) == 1 and configurations[0].get('sha256') == digest
                and type(configurations[0].get('size_bytes')) is int
                and configurations[0]['size_bytes'] == len(data),
                'configuration bytes differ from the manifest')
        identities.append(dict(configurationSHA256=digest, vocabularySize=vocabulary))
    require(identities[0] == identities[1], 'rank configuration identities differ')
    return identities[0]


def validate_report(record, spec):
    identity = validate_spec(spec)
    if identity is None:
        return
    require(record.get('modelFamily') == 'qwen35' and record.get('feedForwardKind') == 'dense',
            'report must describe real dense Qwen')
    for field, value in identity.items():
        require(type(record.get(field)) is type(value) and record[field] == value,
                f'report {field} differs from admitted configuration')
    # General report validation already binds rank, transport, flags, aggregate,
    # layout and every source/selected counter. Add this opt-in's payload caps.
    receipt, storage = record['directShardLoad'], record['partitionStorage']
    require(storage['sourceModelTensorBytes'] <= MAX_TEXT_BYTES, 'canonical text payload exceeds 6 GiB')
    require(all(rank['loadedTensorBytes'] <= MAX_RANK_BYTES for rank in storage['ranks'])
            and sum(rank['loadedTensorBytes'] for rank in storage['ranks']) <= MAX_PAIR_BYTES,
            'selected stored payload exceeds rank/pair limits')
    require(receipt['largestHostTensorBytes'] <= MAX_HOST_TENSOR_BYTES,
            'largest selected host tensor exceeds 512 MiB')


def validate_capture(path, record, spec):
    if not enabled(spec):
        return
    # Swift emits at most 1M Float32 numbers; 32 MiB bounds JSON parsing overhead.
    try:
        require(path.stat().st_size <= MAX_CAPTURE_JSON_BYTES, 'captured logits file exceeds 32 MiB')
    except OSError as error:
        raise ValueError('local_correctness: complete captured logits file is required') from error
    _, rows = read_json(path, MAX_CAPTURE_JSON_BYTES)
    require(isinstance(rows, list) and len(rows) == spec['workload']['decode_tokens'],
            'captured logits must contain every output row')
    vocabulary = record['vocabularySize']
    for index, row in enumerate(rows):
        require(isinstance(row, list) and len(row) == vocabulary,
                'captured logit row differs from vocabulary size')
        try:
            finite = all(type(value) in (int, float) and math.isfinite(value) for value in row)
        except OverflowError:
            finite = False
        require(finite, 'captured logits must contain finite numbers')
        require(row.index(max(row)) == record['runs'][0]['localArgmaxTokens'][index],
                'captured logits disagree with reported local argmax')
