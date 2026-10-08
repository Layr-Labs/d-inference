#!/usr/bin/env python3
"""CPU-only comparison of bounded schema-1 Gemma boundary diagnostics.

No MLX import, GPU work, performance claim, or numerical-quality pass budget.
Router IDs are stock replays from captured logits, never private intercepted IDs.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys


TOP_KEYS = {'schemaVersion', 'correctnessOnly', 'evaluationSchedule', 'routerIDsAreReplayed',
            'identity', 'tokensPerBoundary', 'records'}
RECORD_KEYS = {'path', 'stage', 'call', 'tokenStart', 'shape', 'dtype', 'nativeSHA256', 'values'}
BRANCH_STAGES = {'branch.input', 'input_norm', 'projection.input', 'branch.local',
                 'branch.reduced', 'output_norm.input', 'output_norm.output'}
NORM_STAGES = {'norm.input', 'norm.output'}
ROUTER_STAGES = {'router.input', 'router.logits'}
PATH = re.compile(r'(?P<prefix>language_model\.)?model\.layers\.(?P<layer>[0-3])\.'
                  r'(?P<module>post_feedforward_layernorm_[12]|post_attention_layernorm|'
                  r'post_feedforward_layernorm|router\.proj)')
HASH = re.compile('[0-9a-f]{64}')
DIFFERENT_IDENTITIES = {'rank', 'worldSize', 'partition', 'partitionPlanSHA256'}
IDENTITY_KEYS = DIFFERENT_IDENTITIES | {'configurationSHA256', 'syntheticProfile', 'syntheticDType',
                                     'ffnBranchPrecision', 'seed', 'promptSHA256', 'teacherSHA256', 'chunkSize'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def closed_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError('Nonfinite JSON constant: ' + value)


def f32(value):
    try:
        result = struct.unpack('<f', struct.pack('<f', value))[0]
    except (OverflowError, struct.error):
        raise ValueError('Value overflows Float32') from None
    require(math.isfinite(result), 'Nonfinite Float32 value')
    return result


def finite_number(value):
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        return False


def native_bytes(values, dtype):
    raw = struct.pack(f'<{len(values)}f', *values)
    if dtype == 'float32':
        return raw
    result = bytearray()
    for offset in range(0, len(raw), 4):
        require(raw[offset:offset + 2] == b'\0\0', 'BF16 value reconstruction would require rounding')
        result.extend(raw[offset + 2:offset + 4])
    return bytes(result)


def key(record):
    return record['path'], record['stage'], record['call']


def coordinate(record):
    return {name: record[name] for name in ('path', 'stage', 'call', 'tokenStart', 'shape', 'dtype')}


def stages_for(path):
    match = PATH.fullmatch(path)
    require(match is not None, 'Unsupported boundary path: ' + path)
    module = match['module']
    if module.endswith(('_1', '_2')):
        return BRANCH_STAGES
    return ROUTER_STAGES if module == 'router.proj' else NORM_STAGES


def validate_router(record):
    ids = record.get('replayedExpertIDs')
    if record['stage'] != 'router.logits':
        require('replayedExpertIDs' not in record, 'Router IDs on a non-router-logits boundary')
        return
    if ids is None:
        require('replayedExpertIDs' not in record, 'Optional replayedExpertIDs must be omitted, not null')
        return
    require(isinstance(ids, list) and len(ids) == record['shape'][1] * 2 and
            all(integer(value, 0, 3) for value in ids), 'Malformed replayed top2 expert IDs')
    for row in range(record['shape'][1]):
        chosen = ids[row * 2:row * 2 + 2]
        logits = record['values'][row * 4:row * 4 + 4]
        require(len(set(chosen)) == 2, 'Duplicate selected expert ID')
        require(min(logits[i] for i in chosen) >= max(logits[i] for i in range(4) if i not in chosen),
                'Replayed IDs are not an admissible top2 set of captured logits')


def load_trace(path):
    path = Path(path)
    require(path.stat().st_size <= 192 * 1024 * 1024, 'Trace exceeds bounded JSON file size')
    raw = path.read_bytes()
    value = json.loads(raw, object_pairs_hook=closed_object, parse_constant=reject_constant,
                       parse_int=lambda text: -0.0 if text == '-0' else int(text))
    require(isinstance(value, dict) and set(value) == TOP_KEYS, 'Trace has missing or unknown top-level fields')
    require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1, 'Expected trace schemaVersion 1')
    require(value['correctnessOnly'] is True and value['routerIDsAreReplayed'] is True,
            'Trace must declare correctness-only and replayed router IDs')
    require(value['evaluationSchedule'] == 'explicit-chunks-full-logits-and-captures', 'Unexpected evaluation schedule')
    require(integer(value['tokensPerBoundary'], 1, 143), 'Invalid token coverage')
    identity = value['identity']
    require(isinstance(identity, dict) and identity and
            all(isinstance(k, str) and isinstance(v, str) for k, v in identity.items()), 'Identity must be string fields')
    records = value['records']
    require(isinstance(records, list) and 0 < len(records) <= 143 * 96, 'Invalid record count')
    calls, starts, stage_sets, index = {}, {}, {}, {}
    total = 0
    for record in records:
        require(isinstance(record, dict) and RECORD_KEYS <= set(record) <= RECORD_KEYS | {'replayedExpertIDs'},
                'Record has missing or unknown fields')
        path_name, stage = record['path'], record['stage']
        require(isinstance(path_name, str) and isinstance(stage, str) and stage in stages_for(path_name),
                'Stage does not match its boundary path')
        require(integer(record['call'], 0, 142) and integer(record['tokenStart'], 0, 142), 'Invalid call/token coordinate')
        shape = record['shape']
        width = 4 if stage == 'router.logits' else 128
        require(isinstance(shape, list) and len(shape) == 3 and all(type(d) is int for d in shape)
                and shape[0] == 1 and 1 <= shape[1] <= 128 and shape[2] == width, 'Unsupported boundary shape')
        require(record['dtype'] in ('float32', 'bfloat16'), 'Unsupported boundary dtype')
        require(isinstance(record['nativeSHA256'], str) and HASH.fullmatch(record['nativeSHA256']), 'Invalid native SHA256')
        values = record['values']
        require(isinstance(values, list) and len(values) == math.prod(shape) and
                all(finite_number(x) for x in values), 'Malformed or nonfinite values')
        record['values'] = [f32(x) for x in values]
        raw_values = native_bytes(record['values'], record['dtype'])
        require(hashlib.sha256(raw_values).hexdigest() == record['nativeSHA256'], 'Values do not reconstruct nativeSHA256')
        record['_bytes'] = raw_values
        boundary = path_name, stage
        require(record['call'] == calls.get(boundary, 0) and record['tokenStart'] == starts.get(boundary, 0),
                'Nonconsecutive calls or token coordinates')
        calls[boundary] = record['call'] + 1
        starts[boundary] = record['tokenStart'] + shape[1]
        stage_sets.setdefault(path_name, set()).add(stage)
        require(key(record) not in index, 'Duplicate boundary/call')
        index[key(record)] = record
        total += len(values)
        require(total <= 4_000_000, 'Trace exceeds native captured-value budget')
        validate_router(record)
    require(set(starts.values()) == {value['tokensPerBoundary']} and len(set(calls.values())) == 1,
            'Boundary token or call coverage differs')
    require(len(stage_sets) == 20 and {PATH.fullmatch(p)['layer'] for p in stage_sets} == set('0123'),
            'Expected all five boundary paths in each of four Gemma layers')
    require(all(stages == stages_for(p) for p, stages in stage_sets.items()), 'Missing boundary stages')
    require(len({bool(PATH.fullmatch(p)['prefix']) for p in stage_sets}) == 1, 'Mixed model prefixes')
    for call in range(next(iter(calls.values()))):
        require(len({(r['tokenStart'], r['shape'][1]) for r in records if r['call'] == call}) == 1,
                'A forward has inconsistent boundary token coordinates')
    value['_index'], value['_source'], value['_sha256'] = index, str(path.resolve()), hashlib.sha256(raw).hexdigest()
    return value


def compare_identities(traces):
    names = ('solo', 'rank0', 'rank1')
    identities = [trace['identity'] for trace in traces]
    require(all(set(identity) == IDENTITY_KEYS for identity in identities), 'Identity has missing or unknown fields')
    for name, identity, expected_rank, world, partition in zip(names, identities, ('0', '0', '1'), ('1', '2', '2'), ('none', 'ffn', 'ffn')):
        require(identity['rank'] == expected_rank and identity['worldSize'] == world and identity['partition'] == partition,
                name + ' execution identity does not match its role')
        for field in ('configurationSHA256', 'promptSHA256', 'teacherSHA256'):
            require(HASH.fullmatch(identity[field]), 'Invalid identity hash: ' + field)
        require(identity['partitionPlanSHA256'] == 'none' if name == 'solo' else bool(HASH.fullmatch(identity['partitionPlanSHA256'])),
                'Invalid partition plan identity')
        require(identity['syntheticProfile'] in ('gemma-moe', 'gemma-moe-w8') and
                identity['syntheticDType'] in ('float32', 'bfloat16') and
                identity['ffnBranchPrecision'] in ('native', 'float32'), 'Unsupported model/policy identity')
        require(re.fullmatch(r'0|[1-9][0-9]{0,19}', identity['seed']) and int(identity['seed']) <= 2**64 - 1,
                'Invalid canonical UInt64 seed')
        require(re.fullmatch(r'[1-9][0-9]{0,2}', identity['chunkSize']) and 1 <= int(identity['chunkSize']) <= 128,
                'Invalid bounded chunk size')
    require(identities[1]['partitionPlanSHA256'] == identities[2]['partitionPlanSHA256'], 'Peer partition plans differ')
    for field in set(identities[0]) - DIFFERENT_IDENTITIES:
        require(all(identity[field] == identities[0][field] for identity in identities[1:]), 'Shared identity differs: ' + field)
    return {field: identities[0][field] for field in sorted(set(identities[0]) - DIFFERENT_IDENTITIES)}


def statistics(reference, candidate):
    differences = [b - a for a, b in zip(reference, candidate)]
    peak = max(range(len(differences)), key=lambda i: abs(differences[i]))
    square = math.fsum(d * d for d in differences)
    energy = math.fsum(a * a for a in reference)
    return dict(maxAbsoluteError=abs(differences[peak]), absoluteRMS=math.sqrt(square / len(reference)),
                relativeRMS=math.sqrt(square / max(energy, 1e-30)), peakFlatIndex=peak,
                peakReference=reference[peak], peakCandidate=candidate[peak],
                differingValues=sum(d != 0 for d in differences))


def difference(reference, candidate):
    require(coordinate(reference) == coordinate(candidate), 'Boundary coordinates, shape or dtype differ')
    stats = statistics(reference['values'], candidate['values'])
    width = reference['shape'][2]
    stats.update(peakProcessedToken=reference['tokenStart'] + stats['peakFlatIndex'] // width,
                 peakChannel=stats['peakFlatIndex'] % width,
                 nativeBytesEqual=reference['_bytes'] == candidate['_bytes'])
    return stats


def route_rows(record):
    result = []
    for row in range(record['shape'][1]):
        logits = record['values'][row * 4:row * 4 + 4]
        ordered = sorted(range(4), key=lambda i: (-logits[i], i))
        cutoff = [logits[ordered[1]], logits[ordered[2]]]
        tie = cutoff[0] == cutoff[1]
        ids = record.get('replayedExpertIDs')
        ids = ids[row * 2:row * 2 + 2] if ids is not None else None
        selected = sorted(ids) if ids is not None else sorted(ordered[:2]) if not tie else None
        result.append(dict(processedToken=record['tokenStart'] + row, logits=logits, selectedSet=selected,
                           replayedOrder=ids, cutoff=cutoff, cutoffTie=tie,
                           anyLogitTie=len(set(logits)) < 4))
    return result


def compare_routes(reference, candidate):
    rows = []
    for a, b in zip(route_rows(reference), route_rows(candidate)):
        known = a['selectedSet'] is not None and b['selectedSet'] is not None
        rows.append(dict(processedToken=a['processedToken'], setChange=a['selectedSet'] != b['selectedSet'] if known else None,
                         orderChange=a['replayedOrder'] != b['replayedOrder']
                            if a['replayedOrder'] is not None and b['replayedOrder'] is not None else None,
                         reference=a, candidate=b))
    return dict(changedSets=sum(row['setChange'] is True for row in rows),
                changedOrders=sum(row['orderChange'] is True for row in rows),
                unresolvedTieRows=sum(row['setChange'] is None for row in rows),
                referenceCutoffTies=sum(row['reference']['cutoffTie'] for row in rows),
                candidateCutoffTies=sum(row['candidate']['cutoffTie'] for row in rows), rows=rows)


def partial_sums(traces):
    result = []
    zero, one = traces[1]['_index'], traces[2]['_index']
    for record in traces[0]['records']:
        if record['stage'] != 'branch.local':
            continue
        a, b = zero[key(record)], one[key(record)]
        reduced_key = record['path'], 'branch.reduced', record['call']
        targets = [trace['_index'][reduced_key] for trace in traces[1:]]
        item = dict(path=record['path'], call=record['call'], tokenStart=record['tokenStart'], dtype=a['dtype'])
        if a['dtype'] != 'float32':
            item.update(status='skipped', reason='Native BF16 collective arithmetic is not approximated by this Float32 oracle')
        else:
            require(b['dtype'] == 'float32' and all(t['dtype'] == 'float32' for t in targets), 'Partial/reduced sum dtype differs')
            summed = [f32(x + y) for x, y in zip(a['values'], b['values'])]
            raw = native_bytes(summed, 'float32')
            checks = [dict(rank=rank, exact=raw == target['_bytes'], **statistics(summed, target['values']))
                      for rank, target in enumerate(targets)]
            item.update(status='checked', exact=all(check['exact'] for check in checks), ranks=checks)
        result.append(item)
    return result


def compare(traces):
    identity = compare_identities(traces)
    reference, zero, one = traces
    expected = [key(record) for record in reference['records']]
    require(all(set(trace['_index']) == set(expected) for trace in traces[1:]), 'Boundary keys differ')
    same_order = all([key(record) for record in trace['records']] == expected for trace in traces[1:])
    comparisons, peer_failures, routing = [], [], []
    first_any = first_shared = None
    for sequence, original in enumerate(reference['records']):
        a, b = zero['_index'][key(original)], one['_index'][key(original)]
        stats = difference(original, a)
        rank1_stats = difference(original, b)
        peers = difference(a, b)
        local = original['stage'] == 'branch.local'
        ids_equal = a.get('replayedExpertIDs') == b.get('replayedExpertIDs')
        record = dict(sequence=sequence, **coordinate(original), expectedPartialDifference=local,
                      soloVsRank0=stats, soloVsRank1=rank1_stats, rank0VsRank1=peers, peerReplayedIDsEqual=ids_equal)
        comparisons.append(record)
        if not peers['nativeBytesEqual'] or not ids_equal:
            if not local:
                peer_failures.append(record)
        if not stats['nativeBytesEqual']:
            if first_any is None: first_any = record
            if first_shared is None and not local: first_shared = record
        if original['stage'] == 'router.logits':
            routing.append(dict(sequence=sequence, path=original['path'], call=original['call'],
                                **compare_routes(original, a)))
    sums = partial_sums(traces)
    return dict(schemaVersion=1, kind='gemma_boundary_cpu_comparison', correctnessOnly=True,
                analyzerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                numericalQualification='none; diagnostic differences are reported without a broad pass budget',
                routerIDMeaning='Stock replay from captured logits; private IDs were not intercepted. '
                    'Missing replay IDs are resolved only when the top2 cutoff is strict.',
                float32SumMeaning='Each native Float32 partial is reconstructed from its original bytes; '
                    'they are added in binary64 and rounded once to Float32, then compared byte-for-byte with the reduced boundary.',
                sources=[dict(path=t['_source'], sha256=t['_sha256'], identity=t['identity']) for t in traces],
                sharedIdentity=identity, recordsPerTrace=len(expected), recordOrdersEqual=same_order,
                tokensPerBoundary=reference['tokensPerBoundary'],
                peerExactExceptLocal=not peer_failures, peerMismatchCount=len(peer_failures), peerMismatches=peer_failures,
                firstDifferenceIncludingExpectedPartials=first_any, firstSharedBoundaryDifference=first_shared,
                comparisonRecords=comparisons, float32PartialSums=sums,
                float32PartialSumChecks=sum(s['status'] == 'checked' for s in sums),
                float32PartialSumFailures=sum(s.get('exact') is False for s in sums),
                nativeBF16SumChecksSkipped=sum(s['status'] == 'skipped' for s in sums),
                changedRouterSets=sum(r['changedSets'] for r in routing),
                changedRouterOrders=sum(r['changedOrders'] for r in routing),
                unresolvedRouterTieRows=sum(r['unresolvedTieRows'] for r in routing),
                referenceRouterCutoffTies=sum(r['referenceCutoffTies'] for r in routing),
                candidateRouterCutoffTies=sum(r['candidateCutoffTies'] for r in routing), routing=routing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('solo', type=Path)
    parser.add_argument('rank0', type=Path)
    parser.add_argument('rank1', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        require(not args.output.exists(), 'Output already exists; preserve prior diagnostic evidence')
        result = compare([load_trace(path) for path in (args.solo, args.rank0, args.rank1)])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open('x') as stream:
            json.dump(result, stream, indent=2, allow_nan=False)
            stream.write('\n')
        first = result['firstSharedBoundaryDifference']
        print(f"{result['recordsPerTrace']} boundaries; peers exact outside local partials: {result['peerExactExceptLocal']}; "
              f"F32 sum failures: {result['float32PartialSumFailures']}; route-set changes: {result['changedRouterSets']}")
        if first:
            print(f"First shared-boundary difference: {first['path']} {first['stage']} call {first['call']}; "
                  f"maxabs {first['soloVsRank0']['maxAbsoluteError']:.9g}, relative RMS {first['soloVsRank0']['relativeRMS']:.9g}")
        print(args.output)
        return 0 if result['peerExactExceptLocal'] and result['float32PartialSumFailures'] == 0 else 1
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print('Invalid trace comparison: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
