"""Complete global state metadata; only the position-offset bytes are reconstructible."""
import math
import struct
from audit_common import FRONTIER, fields, exact, integer, sha
from recorded_math import digest, require


def state_geometry(start=0, end=32):
    rows = []
    for layer in range(start, end):
        if layer % 4 == 3:
            components = [('kv.keys', [1, 4, FRONTIER, 256], 'bfloat16', 2),
                          ('kv.position_offsets', [1], 'int32', 4),
                          ('kv.values', [1, 4, FRONTIER, 256], 'bfloat16', 2)]
        else:
            components = [('conv', [1, 3, 8192], 'bfloat16', 2),
                          ('ssm', [1, 32, 128, 128], 'float32', 4)]
        for component, shape, dtype, width in components:
            rows.append(dict(globalLayerIndex=layer, component=component, shape=shape,
                             dtype=dtype, byteCount=math.prod(shape) * width))
    return rows


def state_fingerprint(entries):
    rows = ['cbv2-owned-state-v1', 'tokens=' + str(FRONTIER)]
    rows.extend('{globalLayerIndex}|{component}|{shape}|{dtype}|{byteCount}|{sha256}'.format(**e)
                for e in entries)
    return digest('\n'.join(rows).encode())


def check_entries(entries, start=0, end=32):
    geometry = state_geometry(start, end)
    require(type(entries) is list and len(entries) == len(geometry), 'State component count differs')
    for entry, expected in zip(entries, geometry):
        fields(entry, 'globalLayerIndex component shape dtype byteCount sha256', 'state entry')
        exact({k: entry[k] for k in expected}, expected, 'ordered state geometry')
        sha(entry['sha256'])
        if entry['component'] == 'kv.position_offsets':
            exact(entry['sha256'], digest(struct.pack('<i', FRONTIER)), 'native Int32 position offset')
    return sum(e['byteCount'] for e in entries), state_fingerprint(entries)


def check_state(state):
    fields(state, 'committedTokens entries logicalByteCount fingerprint', 'reference state')
    exact(state['committedTokens'], FRONTIER, 'state frontier')
    size, pin = check_entries(state['entries'])
    exact(state['logicalByteCount'], size, 'state logical bytes')
    exact(state['fingerprint'], pin, 'state fingerprint')
    return state['entries']
