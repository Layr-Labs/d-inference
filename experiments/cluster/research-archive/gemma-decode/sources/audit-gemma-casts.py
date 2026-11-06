#!/usr/bin/env python3
"""Independent integer-bit Float32->BF16 nearest-even audit of final trace boundaries."""

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys

comparator = Path(__file__).with_name('compare-gemma-boundaries.py')
spec = importlib.util.spec_from_file_location('gemma_comparator', comparator)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def round_bf16(value):
    source = bits(value)
    rounded = (source + 0x7fff + ((source >> 16) & 1)) & 0xffff0000
    return struct.unpack('<f', struct.pack('<I', rounded))[0]


def flip_record(record, index, a, b):
    before_key = record['path'], 'branch.reduced', record['call']
    after_key = record['path'], 'output_norm.output', record['call']
    before = [trace['_index'][before_key]['values'][index] for trace in (a, b)]
    after = [trace['_index'][m.key(record)]['values'][index] for trace in (a, b)]
    norm = [trace['_index'][after_key]['values'][index] for trace in (a, b)]
    midpoint = (after[0] + after[1]) / 2
    return dict(path=record['path'], call=record['call'], processedToken=record['tokenStart'] + index // 128,
                channel=index % 128, beforeFloat32=before, beforeBitPatterns=[f'{bits(v):08x}' for v in before],
                afterBF16=after, afterBranchNorm=norm, midpoint=midpoint,
                signedDistanceToMidpoint=[v - midpoint for v in before],
                absoluteDifferenceBefore=abs(before[0] - before[1]),
                absoluteDifferenceAfter=abs(after[0] - after[1]),
                bothMatchNearestEven=[round_bf16(v) for v in before] == after)


def main(root):
    output = root / 'comparison-cast-audit.json'
    m.require(not output.exists(), 'Preserve prior cast audit')
    cases = []
    for comparison in sorted(root.glob('comparison-gemma-*.json')):
        case = comparison.stem.removeprefix('comparison-')
        locations = [(root / (case + '-capture-solo') / 'rank-0.trace.json'),
                     (root / (case + '-capture-ffn') / 'rank-0.trace.json'),
                     (root / (case + '-capture-ffn') / 'rank-1.trace.json')]
        traces = [m.load_trace(path) for path in locations]
        m.compare_identities(traces)
        audited = dict(bfloat16=0, float32=0)
        failures = []
        for role, trace in zip(('solo', 'rank0', 'rank1'), traces):
            for record in trace['records']:
                if record['stage'] != 'output_norm.input': continue
                reduced = trace['_index'][record['path'], 'branch.reduced', record['call']]
                m.require(reduced['dtype'] == 'float32' and reduced['shape'] == record['shape'], 'Expected widened branch')
                for index, (before, after) in enumerate(zip(reduced['values'], record['values'])):
                    expected = round_bf16(before) if record['dtype'] == 'bfloat16' else before
                    audited[record['dtype']] += 1
                    if bits(expected) != bits(after):
                        failures.append(dict(role=role, **m.coordinate(record), index=index,
                                             before=before, after=after, expected=expected))
        first = surviving = None
        a, b = traces[:2]
        for record in a['records']:
            if record['stage'] != 'output_norm.input' or record['dtype'] != 'bfloat16': continue
            candidate = b['_index'][m.key(record)]
            for index, (x, y) in enumerate(zip(record['values'], candidate['values'])):
                if bits(x) == bits(y): continue
                flip = flip_record(record, index, a, b)
                if first is None: first = flip
                if surviving is None and flip['afterBranchNorm'][0] != flip['afterBranchNorm'][1]: surviving = flip
        item = dict(case=case, traceSHA256=[t['_sha256'] for t in traces], auditedValues=audited,
                    failureCount=len(failures), failures=failures,
                    earliestCastFlip=first, earliestCastFlipSurvivingSameCoordinateNorm=surviving)
        cases.append(item)
        print(case, audited, 'failures', len(failures))
        if surviving: print('surviving', json.dumps(surviving, sort_keys=True))
    m.require(len(cases) == 4, 'Expected all four final cases')
    result = dict(kind='gemma_cast_rounding_audit', correctnessOnly=True,
                  method='Reconstruct original Float32/BF16 bytes; BF16 round-to-nearest-even via integer bias 0x7fff + retained LSB; compare bit patterns.',
                  numericalQualification='None; exact cast semantics and local propagation only.',
                  auditorSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  comparatorSHA256=hashlib.sha256(comparator.read_bytes()).hexdigest(), cases=cases)
    with output.open('x') as stream: json.dump(result, stream, indent=2, allow_nan=False); stream.write('\n')
    print(output)
    return int(any(case['failureCount'] for case in cases))


if __name__ == '__main__': sys.exit(main(Path(sys.argv[1])))
