"""Small strict metadata helpers; never evaluate historical paths or code."""
import hashlib
import json
import math
from pathlib import PurePosixPath
import re


def require(value, message):
    if not value:
        raise ValueError(message)


def fields(value, names, where):
    require(type(value) is dict and set(value) == set(names.split()), where + ': keys differ')
    return value


def same(left, right, where):
    require(type(left) is type(right), where + ': type differs')
    if type(right) is dict:
        require(set(left) == set(right), where + ': keys differ')
        for key in right:
            same(left[key], right[key], where + '.' + key)
    elif type(right) is list:
        require(len(left) == len(right), where + ': count differs')
        for a, b in zip(left, right):
            same(a, b, where)
    else:
        require(left == right, where + ': value differs')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def pin(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid SHA256 pin')
    return value


def integer(value, where, low=0, high=2**63-1):
    require(type(value) is int and low <= value <= high, where + ': invalid integer')
    return value


def text(value, where, maximum=4096):
    require(type(value) is str and 0 < len(value.encode('utf-8')) <= maximum
            and all(ord(c) >= 32 and ord(c) != 127 for c in value), where + ': invalid text')
    return value


def path_text(value, absolute):
    text(value, 'historical path')
    path = PurePosixPath(value)
    require(path.is_absolute() == absolute and str(path) == value and '..' not in path.parts
            and '\\' not in value and not value.startswith('//') and value not in ('/', '.'),
            'Historical path is not normalized')
    return path


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def parse(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def bad(_):
        raise ValueError('Nonfinite JSON number')
    def floating(value):
        result = float(value)
        require(math.isfinite(result), 'Nonfinite JSON number')
        return result
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=bad, parse_float=floating)
