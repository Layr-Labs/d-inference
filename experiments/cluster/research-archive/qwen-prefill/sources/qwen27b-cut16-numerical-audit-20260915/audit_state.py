"""Complete global state metadata; only the position-offset bytes are reconstructible."""
import math
import struct
from audit_common import FRONTIER, fields, exact, integer, sha
from recorded_math import digest, require
from audit_scope import LEGACY


def state_geometry(start=0, end=None, scope=LEGACY):
    end = scope.model['layers'] if end is None else end
    FRONTIER = scope.frontier
    model = scope.model
    rows = []
    for layer in range(start, end):
        if (layer + 1) % model['interval'] == 0:
            components = [('kv.keys', [1, model['kv_heads'], FRONTIER, model['head_dim']], 'bfloat16', 2),
                          ('kv.position_offsets', [1], 'int32', 4),
                          ('kv.values', [1, model['kv_heads'], FRONTIER, model['head_dim']], 'bfloat16', 2)]
        else:
            components = [('conv', [1, model['conv_history'], model['conv_channels']], 'bfloat16', 2),
                          ('ssm', [1, model['linear_value_heads'], model['linear_value_dim'],
                                   model['linear_key_dim']], 'float32', 4)]
        for component, shape, dtype, width in components:
            rows.append(dict(globalLayerIndex=layer, component=component, shape=shape,
                             dtype=dtype, byteCount=math.prod(shape) * width))
    return rows


def state_fingerprint(entries, scope=LEGACY):
    FRONTIER = scope.frontier
    rows = ['cbv2-owned-state-v1', 'tokens=' + str(FRONTIER)]
    rows.extend('{globalLayerIndex}|{component}|{shape}|{dtype}|{byteCount}|{sha256}'.format(**e)
                for e in entries)
    return digest('\n'.join(rows).encode())


def check_entries(entries, start=0, end=None, scope=LEGACY):
    FRONTIER = scope.frontier
    geometry = state_geometry(start, end, scope)
    require(type(entries) is list and len(entries) == len(geometry), 'State component count differs')
    for entry, expected in zip(entries, geometry):
        fields(entry, 'globalLayerIndex component shape dtype byteCount sha256', 'state entry')
        exact({k: entry[k] for k in expected}, expected, 'ordered state geometry')
        sha(entry['sha256'])
        if entry['component'] == 'kv.position_offsets':
            exact(entry['sha256'], digest(struct.pack('<i', FRONTIER)), 'native Int32 position offset')
    return sum(e['byteCount'] for e in entries), state_fingerprint(entries, scope)


def check_state(state, scope=LEGACY):
    FRONTIER = scope.frontier
    fields(state, 'committedTokens entries logicalByteCount fingerprint', 'reference state')
    exact(state['committedTokens'], FRONTIER, 'state frontier')
    size, pin = check_entries(state['entries'], scope=scope)
    exact(state['logicalByteCount'], size, 'state logical bytes')
    exact(state['fingerprint'], pin, 'state fingerprint')
    return state['entries']
