"""Reads ONLY the retained JSON metadata and raw JSON header captures."""
import hashlib
import json
import math
import os
import stat
from pathlib import Path
from geometry import DTYPE_BYTES, expected_text_tensors, require, validate_geometry

ARTIFACT = Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-26b-distributed-artifact-20260915')
AGGREGATE = '2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785'
CONFIG_SHA = '29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa'
INDEX_SHA = '5455e83705bbdd4e3702c7d4f9d49d4900e84533036628f74500538075dd5c80'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def read_json(path, pins):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        require(stat.S_ISREG(st.st_mode) and 0 < st.st_size <= 2 * 1024 * 1024,
                "not a bounded metadata file")
        with os.fdopen(fd, 'rb', closefd=False) as handle:
            raw = handle.read(st.st_size + 1)
        require(len(raw) == st.st_size, "metadata changed during read")
    finally:
        os.close(fd)
    value = json.loads(raw, object_pairs_hook=unique_pairs,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
    pins.append({"path": str(path), "sizeBytes": len(raw), "sha256": digest(raw)})
    return value, raw


def validate_inventory(manifest, inventory, index, headers):
    files = {f['path']: f for f in manifest['files']}
    require(len(files) == manifest['file_count'] == 10, "manifest file coverage")
    require(sum(f['size_bytes'] for f in files.values()) == manifest['total_size_bytes'],
            "manifest size total")
    require(len(inventory['files']) == len(headers) == 3, "header file coverage")
    combined, total = {}, 0
    for captured in inventory['files']:
        name = captured['path']
        header, raw = headers[name]
        require(captured['payloadSHA256NotVerified'] is True, "unexpected payload claim")
        require(captured['headerBytes'] == len(raw) and captured['headerSHA256'] == digest(raw),
                "header capture identity")
        require(header.get('__metadata__') == {"format": "mlx"}, "header format")
        spans = []
        for key, descriptor in header.items():
            if key == '__metadata__':
                continue
            require(key not in combined, "duplicate tensor across headers")
            require(set(descriptor) == {'dtype', 'shape', 'data_offsets'}, "descriptor schema")
            shape, dtype, offsets = descriptor['shape'], descriptor['dtype'], descriptor['data_offsets']
            require(dtype in DTYPE_BYTES and isinstance(shape, list) and shape
                    and all(type(x) is int and 0 < x <= 262144 for x in shape),
                    "invalid shape/dtype")
            require(isinstance(offsets, list) and len(offsets) == 2
                    and all(type(x) is int and x >= 0 for x in offsets), "offset type")
            size = math.prod(shape) * DTYPE_BYTES[dtype]
            require(offsets[1] - offsets[0] == size, "shape/span mismatch")
            spans.append(offsets)
            require(index['weight_map'].get(key) == name, "index/header shard mismatch")
            combined[key] = dict(descriptor, file=name)
            total += size
        end = 0
        for start, stop in sorted(spans):
            require(start == end and stop > start, "header gap/overlap")
            end = stop
        require(8 + len(raw) + end == files[name]['size_bytes'], "declared shard size mismatch")
    require(combined == inventory['tensors'], "captured inventory/header mismatch")
    require(set(combined) == set(index['weight_map']), "index coverage mismatch")
    require(total == index['metadata']['total_size'], "index payload-byte total")
    expected = expected_text_tensors()
    text = {key: value for key, value in combined.items() if key.startswith('language_model.')}
    require(set(text) == set(expected), "text tensor coverage differs")
    for key, value in text.items():
        require(value['shape'] == expected[key]['shape'] and value['dtype'] == expected[key]['dtype'],
                "text packed shape/dtype differs: " + key)
    require(all(key.startswith(('language_model.', 'vision_tower.', 'embed_vision.'))
                for key in combined), "unknown top-level source component")
    require(len(combined) == 1697 and len(text) == 1339, "artifact tensor count differs")
    return combined


def load_artifact():
    pins = []
    manifest, _ = read_json(ARTIFACT / 'manifest.json', pins)
    config, raw_config = read_json(ARTIFACT / 'metadata/config.json', pins)
    index, raw_index = read_json(ARTIFACT / 'metadata/model.safetensors.index.json', pins)
    inventory, _ = read_json(ARTIFACT / 'tensor-inventory.json', pins)
    require(manifest['aggregate_sha256'] == AGGREGATE
            and manifest['model_id'] == 'gemma-4-26b-qat-4bit', "artifact identity")
    require(digest(raw_config) == CONFIG_SHA and digest(raw_index) == INDEX_SHA,
            "retained config/index identity")
    declared = {item['path']: item for item in manifest['files']}
    require(declared['config.json']['sha256'] == CONFIG_SHA
            and declared['model.safetensors.index.json']['sha256'] == INDEX_SHA,
            "manifest metadata binding")
    validate_geometry(config)
    headers = {}
    for number in range(1, 4):
        name = f'model-{number:05d}-of-00003.safetensors'
        headers[name] = read_json(ARTIFACT / 'tensor-headers' / (name + '.header.json'), pins)
    tensors = validate_inventory(manifest, inventory, index, headers)
    return {"config": config, "manifest": manifest, "inventory": inventory,
            "index": index, "headers": headers, "tensors": tensors, "pins": pins}
