"""Validate the common two-rank storage commitment, including unequal shards.

This binds native source metadata and rank selections; it does not independently
re-read the checkpoint or qualify numerical results. Real runs additionally bind
the same commitment and source counters into their verified direct-load receipt.
"""

import hashlib
import json
import re


SOURCE_FIELDS = ('sourceModelTensorBytes', 'sourceFFNTensorBytes',
                 'sourceShardedFFNTensorBytes', 'sourceShardedTensorBytes')
STORAGE_KEYS = {'schemaVersion', 'sourceTensorManifestSHA256', 'ranks', *SOURCE_FIELDS}
RANK_KEYS = {'rank', 'parameterLayoutSHA256', 'loadedTensorBytes', 'selectedShardedTensorBytes'}


def require(condition, message):
    if not condition:
        raise ValueError('Invalid partitionStorage: ' + message)


def fingerprint(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def positive(value):
    return type(value) is int and 0 < value <= 2**63 - 1


def commitment_hash(storage):
    encoded = json.dumps(storage, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                         allow_nan=False).encode('utf-8')
    return hashlib.sha256(encoded).hexdigest()


def validate_storage(storage, partition, rank, local_layout):
    require(isinstance(storage, dict) and set(storage) == STORAGE_KEYS, 'missing or unknown fields')
    require(type(storage['schemaVersion']) is int and storage['schemaVersion'] == 1, 'expected schemaVersion 1')
    require(fingerprint(storage['sourceTensorManifestSHA256']), 'invalid source tensor manifest SHA256')
    require(all(positive(storage[key]) for key in SOURCE_FIELDS), 'source counters must be positive integers')
    source, ffn, sharded_ffn, sharded = (storage[key] for key in SOURCE_FIELDS)
    require(sharded_ffn <= ffn <= source and sharded_ffn <= sharded <= source,
            'inconsistent source tensor byte accounting')
    require((partition == 'ffn' and sharded == sharded_ffn) or
            (partition == 'full' and sharded > sharded_ffn), 'does not describe requested partition')
    entries = storage['ranks']
    require(isinstance(entries, list) and len(entries) == 2, 'expected two ordered rank entries')
    for expected_rank, entry in enumerate(entries):
        require(isinstance(entry, dict) and set(entry) == RANK_KEYS, 'invalid rank entry fields')
        require(type(entry['rank']) is int and entry['rank'] == expected_rank, 'rank entries must be ordered 0, 1')
        require(fingerprint(entry['parameterLayoutSHA256']), 'invalid rank layout SHA256')
        require(positive(entry['loadedTensorBytes']) and positive(entry['selectedShardedTensorBytes']),
                'rank counters must be positive integers')
        require(entry['loadedTensorBytes'] == source - sharded + entry['selectedShardedTensorBytes'],
                'inconsistent rank tensor byte accounting')
    require(sum(entry['selectedShardedTensorBytes'] for entry in entries) == sharded,
            'selected bytes must conserve the source sharded bytes')
    require(type(rank) is int and rank in (0, 1), 'invalid local rank')
    require(entries[rank]['parameterLayoutSHA256'] == local_layout, 'local parameter layout differs from commitment')
    return entries[rank]
