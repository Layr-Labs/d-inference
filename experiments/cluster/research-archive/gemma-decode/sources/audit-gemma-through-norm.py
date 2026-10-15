#!/usr/bin/env python3
"""CPU-only audit of bounded BF16 Gemma float32-through-norm traces.

This independently checks the declared cast boundary, not RMSNorm numerics,
router decisions, model quality, transport, or performance. No MLX dependency.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys


TOP = {'schemaVersion', 'correctnessOnly', 'evaluationSchedule', 'routerIDsAreReplayed',
       'identity', 'tokensPerBoundary', 'records'}
RECORD = {'path', 'stage', 'call', 'tokenStart', 'shape', 'dtype', 'nativeSHA256', 'values'}
ROLE_FIELDS = {'rank', 'worldSize', 'partition', 'partitionPlanSHA256'}
IDENTITY = ROLE_FIELDS | {'configurationSHA256', 'syntheticProfile', 'syntheticDType',
                         'ffnBranchPrecision', 'seed', 'promptSHA256', 'teacherSHA256', 'chunkSize'}
BRANCH_DTYPES = {'branch.input': 'bfloat16', 'input_norm': 'bfloat16',
                 'projection.input': 'float32', 'branch.local': 'float32',
                 'branch.reduced': 'float32', 'output_norm.input': 'float32',
                 'output_norm.output': 'float32', 'branch.output': 'bfloat16'}
NORM_DTYPES = {'norm.input': 'bfloat16', 'norm.output': 'bfloat16'}
ROUTER_DTYPES = {'router.input': 'bfloat16', 'router.logits': 'bfloat16'}
PATH = re.compile(r'(?P<prefix>language_model\.)?model\.layers\.(?P<layer>[0-3])\.'
                  r'(?P<module>post_feedforward_layernorm_[12]|post_attention_layernorm|'
                  r'post_feedforward_layernorm|router\.proj)')
HASH = re.compile('[0-9a-f]{64}')


def need(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def closed(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError('Nonfinite JSON constant: ' + value)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def native_bytes(values, dtype):
    need(isinstance(values, list) and all(type(v) in (int, float) for v in values),
         'Values must be numeric scalars')
    try:
        raw = struct.pack(f'<{len(values)}f', *values)
    except (OverflowError, struct.error):
        raise ValueError('Value cannot be represented as Float32') from None
    need(all(math.isfinite(v[0]) for v in struct.iter_unpack('<f', raw)), 'Nonfinite Float32 value')
    if dtype == 'float32':
        return raw
    need(dtype == 'bfloat16', 'Unsupported dtype')
    result = bytearray()
    for (bits,) in struct.iter_unpack('<I', raw):
        need(bits & 0xffff == 0, 'BF16 source value requires rounding to reconstruct')
        result.extend(struct.pack('<H', bits >> 16))
    return bytes(result)


def nearest_even_bf16(raw_float32):
    """Integer IEEE754 round-to-nearest-even; preserves signed zero."""
    return b''.join(struct.pack('<H', ((bits + 0x7fff + ((bits >> 16) & 1)) >> 16) & 0xffff)
                    for (bits,) in struct.iter_unpack('<I', raw_float32))


def stages(path):
    match = PATH.fullmatch(path)
    need(match is not None, 'Unknown model boundary path')
    if match['module'].endswith(('_1', '_2')):
        return BRANCH_DTYPES
    return ROUTER_DTYPES if match['module'] == 'router.proj' else NORM_DTYPES


def load(path):
    path = Path(path)
    need(path.stat().st_size <= 192 * 1024 * 1024, 'Trace exceeds bounded file size')
    raw = path.read_bytes()
    value = json.loads(raw, object_pairs_hook=closed, parse_constant=reject_constant,
                       parse_int=lambda text: -0.0 if text == '-0' else int(text))
    need(isinstance(value, dict) and set(value) == TOP, 'Unexpected trace fields')
    need(type(value['schemaVersion']) is int and value['schemaVersion'] == 1, 'Expected trace schema 1')
    need(value['correctnessOnly'] is True and value['routerIDsAreReplayed'] is True,
         'Trace diagnostic declarations differ')
    need(value['evaluationSchedule'] == 'explicit-chunks-full-logits-and-captures', 'Unexpected schedule')
    need(integer(value['tokensPerBoundary'], 1, 143), 'Invalid total token coverage')
    identity = value['identity']
    need(isinstance(identity, dict) and set(identity) == IDENTITY
         and all(type(v) is str for v in identity.values()), 'Unexpected identity fields')
    need(identity['ffnBranchPrecision'] == 'float32-through-norm'
         and identity['syntheticDType'] == 'bfloat16'
         and identity['syntheticProfile'] in ('gemma-moe', 'gemma-moe-w8'), 'Unsupported audit policy/profile/dtype')
    for field in ('configurationSHA256', 'promptSHA256', 'teacherSHA256'):
        need(HASH.fullmatch(identity[field]), 'Invalid identity hash: ' + field)
    need(re.fullmatch(r'0|[1-9][0-9]{0,19}', identity['seed']) and int(identity['seed']) < 2**64,
         'Invalid canonical seed')
    need(re.fullmatch(r'[1-9][0-9]{0,6}', identity['chunkSize']) and int(identity['chunkSize']) <= 1_000_000,
         'Invalid canonical chunk size')
    records = value['records']
    need(isinstance(records, list) and 0 < len(records) <= 143 * 96, 'Invalid record count')
    index, coverage, calls, paths, coordinates = {}, {}, {}, {}, {}
    total = 0
    for record in records:
        need(isinstance(record, dict) and RECORD <= set(record) <= RECORD | {'replayedExpertIDs'},
             'Unexpected record fields')
        name, stage = record['path'], record['stage']
        need(type(name) is str and type(stage) is str, 'Path and stage must be strings')
        expected = stages(name)
        need(stage in expected and record['dtype'] == expected[stage], 'Boundary dtype/stage contract differs')
        need(integer(record['call'], 0, 142) and integer(record['tokenStart'], 0, 142), 'Invalid call coordinate')
        shape = record['shape']
        width = 4 if stage == 'router.logits' else 128
        need(isinstance(shape, list) and len(shape) == 3 and all(type(n) is int for n in shape)
             and shape[0] == 1 and 1 <= shape[1] <= 128 and shape[2] == width, 'Invalid bounded shape')
        need(isinstance(record['nativeSHA256'], str) and HASH.fullmatch(record['nativeSHA256']), 'Invalid native hash')
        need(isinstance(record['values'], list) and len(record['values']) == math.prod(shape), 'Value count differs')
        native = native_bytes(record['values'], record['dtype'])
        need(sha(native) == record['nativeSHA256'], 'Native byte hash reconstruction differs')
        if 'replayedExpertIDs' in record:
            ids = record['replayedExpertIDs']
            need(stage == 'router.logits' and isinstance(ids, list) and len(ids) == shape[1] * 2
                 and all(integer(v, 0, 3) for v in ids), 'Malformed optional replayed expert IDs')
        key = name, stage
        need(record['call'] == calls.get(key, 0) and record['tokenStart'] == coverage.get(key, 0),
             'Nonconsecutive per-boundary calls/tokens')
        calls[key], coverage[key] = record['call'] + 1, record['tokenStart'] + shape[1]
        paths.setdefault(name, set()).add(stage)
        coordinates.setdefault(record['call'], set()).add((record['tokenStart'], shape[1]))
        record['_raw'] = native
        index[name, stage, record['call']] = record
        total += len(record['values'])
        need(total <= 4_000_000, 'Captured values exceed native bound')
    need(len(paths) == 20 and all(found == set(stages(name)) for name, found in paths.items()),
         'Missing model paths or boundary stages')
    need(len({bool(PATH.fullmatch(name)['prefix']) for name in paths}) == 1, 'Mixed model prefixes')
    need(set(coverage.values()) == {value['tokensPerBoundary']} and len(set(calls.values())) == 1,
         'Unequal call or token coverage across boundaries')
    need(all(len(values) == 1 for values in coordinates.values()), 'Forward coordinates differ between boundaries')
    return dict(identity=identity, records=records, index=index, tokens=value['tokensPerBoundary'],
                calls=next(iter(calls.values())), scalarValues=total, path=str(path.resolve()), sha256=sha(raw))


def audit_trace(trace):
    counts = dict(nativeHashes=len(trace['records']), scalarValues=trace['scalarValues'],
                  boundaryDTypes=len(trace['records']), widenedValues=0, retainedNormInputValues=0, castValues=0)
    for record in trace['records']:
        name, stage, call = record['path'], record['stage'], record['call']
        if stage not in ('projection.input', 'output_norm.input', 'branch.output'):
            continue
        source_stage = {'projection.input': 'input_norm', 'output_norm.input': 'branch.reduced',
                        'branch.output': 'output_norm.output'}[stage]
        source = trace['index'][name, source_stage, call]
        need(source['shape'] == record['shape'] and source['tokenStart'] == record['tokenStart'],
             'Cast coordinate mismatch')
        if stage == 'projection.input':
            expected = native_bytes(source['values'], 'float32')
            count = 'widenedValues'
        elif stage == 'output_norm.input':
            expected, count = source['_raw'], 'retainedNormInputValues'
        else:
            expected, count = nearest_even_bf16(source['_raw']), 'castValues'
        need(expected == record['_raw'], f'Exact boundary conversion differs: {name}:{stage}:{call}')
        counts[count] += len(record['values'])
    need(counts['castValues'] == 8 * 128 * trace['tokens'], 'Expected all eight branch casts per token')
    return dict(path=trace['path'], sha256=trace['sha256'], identity=trace['identity'],
                callsPerBoundary=trace['calls'], tokensPerBoundary=trace['tokens'], counts=counts)


def audit(paths):
    traces = [load(path) for path in paths]
    for trace, rank, world, partition in zip(traces, ('0', '0', '1'), ('1', '2', '2'), ('none', 'ffn', 'ffn')):
        identity = trace['identity']
        need((identity['rank'], identity['worldSize'], identity['partition']) == (rank, world, partition),
             'Trace role identity differs')
        need(identity['partitionPlanSHA256'] == 'none' if partition == 'none'
             else HASH.fullmatch(identity['partitionPlanSHA256']), 'Unexpected partition plan identity')
    need(traces[1]['identity']['partitionPlanSHA256'] == traces[2]['identity']['partitionPlanSHA256'], 'Peer plan mismatch')
    for trace in traces[1:]:
        need(all(trace['identity'][key] == traces[0]['identity'][key] for key in IDENTITY - ROLE_FIELDS),
             'Shared execution identity mismatch')
        need(set(trace['index']) == set(traces[0]['index']), 'Peer/solo boundary coordinates differ')
        for key, record in trace['index'].items():
            reference = traces[0]['index'][key]
            need(all(record[field] == reference[field] for field in ('shape', 'tokenStart', 'dtype')),
                 'Peer/solo boundary shape, dtype or token coverage differs')
    return [audit_trace(trace) for trace in traces]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('solo', type=Path)
    parser.add_argument('rank0', type=Path)
    parser.add_argument('rank1', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    need(not args.output.exists(), 'Preserve historical audit output')
    results = audit([args.solo, args.rank0, args.rank1])
    native = Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference')
    sources = [Path(__file__), *(native / name for name in
               ('FFNBranchPrecision.swift', 'GemmaReductions.swift', 'GemmaBoundaryTrace.swift',
                'GemmaDiagnosticExecution.swift'))]
    receipt = dict(kind='gemma_through_norm_boundary_cpu_audit', correctnessOnly=True,
                   scope='Declared boundary dtypes, native bytes, exact widening, unchanged norm input and post-norm BF16 cast only; no numerical-quality qualification',
                   rounding='IEEE754 Float32 bits + 0x7fff + retained LSB, then retain upper16 bits',
                   sources=[dict(path=str(path.resolve()), sha256=sha(path.read_bytes())) for path in sources],
                   traces=results, totals={key: sum(item['counts'][key] for item in results) for key in results[0]['counts']},
                   passed=True)
    with args.output.open('x') as stream:
        json.dump(receipt, stream, indent=2, allow_nan=False)
        stream.write('\n')
    print(json.dumps(dict(output=str(args.output), passed=True, totals=receipt['totals']), sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print('Audit rejected: ' + str(error), file=sys.stderr)
        sys.exit(1)
