"""Exact extracted frozen recorded-row helpers; see lineage.json."""
import hashlib
import json
import math
import re
import struct
WIDTH = {"float16":2,"bfloat16":2,"float32":4,"uint32":4,"int32":4}

def require(ok, message):
    if not ok:
        raise ValueError(message)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()

def parse_json(text):
    """Preserve Swift JSONEncoder's integer spelling -0 as floating negative zero."""
    def unique(items):
        out = {}
        for key, value in items:
            require(key not in out, 'Duplicate JSON key')
            out[key] = value
        return out
    return json.loads(text, object_pairs_hook=unique,
        parse_int=lambda value: -0.0 if value == '-0' else int(value),
        parse_constant=lambda _: require(False, 'Nonfinite JSON'))

def integer(value, minimum=0):
    require(type(value) is int and value >= minimum, 'Invalid bounded integer')
    return value

def sha_string(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid SHA256')
    return value

def flags(obj, **expected):
    for key, value in expected.items():
        require(obj.get(key) is value, 'Evidence flag differs: ' + key)

def equal(actual, expected, message):
    require(canonical(actual) == canonical(expected), message)

def logical_bytes(record, vocabulary, dtype):
    require(set(record) == {'shape', 'dtype', 'byteCount', 'logicalBytesSHA256', 'values'}, 'Logit record fields differ')
    equal(record['shape'], [1, vocabulary], 'Incomplete vocabulary row')
    require(record['dtype'] == dtype and dtype in ('float16', 'bfloat16', 'float32'), 'Logit dtype differs')
    require(integer(record['byteCount']) == vocabulary * WIDTH[dtype]
        and isinstance(record['values'], list) and len(record['values']) == vocabulary, 'Logit storage count differs')
    result = bytearray()
    for value in record['values']:
        require(type(value) in (int, float) and math.isfinite(value), 'Nonfinite/bool logit')
        try:
            packed = struct.pack('<f', value)
            floating = struct.unpack('<f', packed)[0]
            require(math.isfinite(floating), 'Float32 logit overflow')
            if dtype == 'float16':
                half = struct.pack('<e', floating)
                require(struct.unpack('<e', half)[0] == floating, 'Value not exactly float16')
                result.extend(half)
            elif dtype == 'bfloat16':
                bits = struct.unpack('<I', packed)[0]
                require(bits & 65535 == 0, 'Value not exactly bfloat16')
                result.extend(struct.pack('<H', bits >> 16))
            else:
                result.extend(packed)
        except (OverflowError, struct.error) as error:
            raise ValueError('Out-of-range native logit value') from error
    require(digest(result) == sha_string(record['logicalBytesSHA256']), 'Native logit bytes SHA differs')
    return bytes(result)
