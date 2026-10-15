"""Exact final full-state metadata coverage; component value digests stay opaque."""
import hashlib
from binding_common import fields, integer, pin, require, same


def expected_entries(profile, frontier):
    integer(frontier, 'state frontier', 1, 8319)
    result = []
    for layer in range(profile.layers):
        if (layer + 1) % 4 == 0:
            components = [('kv.keys', [1, 4, frontier, 256], 'bfloat16', 2048 * frontier),
                          ('kv.position_offsets', [1], 'int32', 4),
                          ('kv.values', [1, 4, frontier, 256], 'bfloat16', 2048 * frontier)]
        else:
            components = [('conv', [1, 3, profile.conv_channels], 'bfloat16', 6 * profile.conv_channels),
                          ('ssm', [1, profile.value_heads, 128, 128], 'float32', 4 * profile.value_heads * 128 * 128)]
        for component, shape, dtype, size in components:
            result.append(dict(globalLayerIndex=layer, component=component, shape=shape, dtype=dtype, byteCount=size))
    return result


def fingerprint(frontier, entries):
    lines = ['cbv2-owned-state-v1', 'tokens=' + str(frontier)]
    lines += ['{}|{}|{}|{}|{}|{}'.format(x['globalLayerIndex'], x['component'], x['shape'],
              x['dtype'], x['byteCount'], x['sha256']) for x in entries]
    return hashlib.sha256('\n'.join(lines).encode()).hexdigest()


def validate_state(state, profile, frontier):
    fields(state, 'committedTokens entries logicalByteCount fingerprint', 'finalState')
    same(state['committedTokens'], frontier, 'final state frontier')
    expected = expected_entries(profile, frontier)
    require(type(state['entries']) is list and len(state['entries']) == len(expected), 'Final state coverage is incomplete')
    for actual, metadata in zip(state['entries'], expected):
        fields(actual, 'globalLayerIndex component shape dtype byteCount sha256', 'state entry')
        for name, value in metadata.items():
            same(actual[name], value, 'state.' + name)
        pin(actual['sha256'])
    same(state['logicalByteCount'], sum(x['byteCount'] for x in expected), 'full state logical bytes')
    same(state['fingerprint'], fingerprint(frontier, state['entries']), 'state metadata/digest fingerprint')
