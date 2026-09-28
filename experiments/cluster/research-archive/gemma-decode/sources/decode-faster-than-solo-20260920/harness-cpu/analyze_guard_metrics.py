"""Validate fixed native counters after actual parent/resource retirement."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

import compare_results as original
import compare_results_v2 as retained

CATEGORIES = ('logicalGuard', 'entryGuard', 'ownerGuard', 'environmentGuard',
              'osSnapshot', 'nativeSnapshot', 'outerNativeFault',
              'wireSendCompleted', 'wireReceiveCompleted')
FRESH = 'gemma4_invocation_fresh_observation_v1'
OVERLAP_SHA = '10741437b9dc9db7fc91e5fdc9f18e6860c2d13c723595b2f5f2b18405ef8c44'


def require(value, reason):
    if not value:
        raise ValueError(reason)


def snapshot(value):
    require(value['schema'] == 'gemma4_guard_wall_counters_v1'
            and value['overflow'] is False and value['sameProcessClock'] is True
            and value['categoriesAreInclusive'] is True and value['extraOSReads'] == 0
            and value['extraNativeEvaluations'] == 0
            and value['observerOverheadIncludedInRequestTiming'] is True, 'Invalid guard counter scope')
    rows = value['records']
    require(tuple(row['category'] for row in rows) == CATEGORIES, 'Counter categories changed')
    for row in rows:
        for key in ('count', 'nanoseconds', 'nestedLogicalGuardNanoseconds'):
            require(type(row[key]) is int and 0 <= row[key] < 2**64, 'Counter range or type differs')
        require(row['nestedLogicalGuardNanoseconds'] <= row['nanoseconds'], 'Nested guard exceeds observed interval')
        if row['count'] == 0:
            require(row['nanoseconds'] == row['nestedLogicalGuardNanoseconds'] == 0, 'Zero count has elapsed time')
    return {row['category']: row for row in rows}


def role(case, kind, mode, host, native, policy):
    original.validate_launch(case, kind, mode, host)
    folder = case / kind / mode
    value = original.load(folder, mode)
    comparator = retained
    if value['job'].get('prefillPolicy', 'serial') == 'oneChunkLookahead':
        source = Path(__file__).resolve().parent / 'compare_results_overlap.py'
        require(hashlib.sha256(source.read_bytes()).hexdigest() == OVERLAP_SHA, 'Reviewed overlap comparison changed')
        spec = importlib.util.spec_from_file_location('guard_overlap_comparison', source)
        comparator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(comparator)
    joined = comparator.join_role(case, kind, mode, host)
    require(value['job']['buildIdentitySHA256'] == native, 'Unexpected native identity')
    require(value.get('guardObservationPolicy') == (FRESH if policy == 'invocation' else None), 'Observation policy differs')
    cohort = snapshot(value['guardMetrics'])
    phases = {'prefill': [], 'decode': []}
    for sample in value['samples']:
        metrics = sample['guardMetrics']
        require(metrics['boundary'] == 'request-start_to_first-token-agreement_and_first-to-last-agreement', 'Metric boundary differs')
        for name in phases:
            rows = snapshot(metrics[name])
            count = lambda category: rows[category]['count']
            logical = count('logicalGuard')
            require(logical > 0 and count('entryGuard') == 2 * logical
                    and count('ownerGuard') == logical and count('nativeSnapshot') == logical
                    and count('environmentGuard') == 3 * logical
                    and count('outerNativeFault') == 8 * logical, 'Timed interval callback counts differ from source')
            require(count('osSnapshot') == logical * (1 if policy == 'invocation' else 6), 'Unexpected OS reader count')
            total = sample[name + 'Nanoseconds']
            guard = rows['logicalGuard']['nanoseconds']
            wire = sum(rows[key]['nanoseconds'] for key in CATEGORIES[-2:])
            nested = sum(rows[key]['nestedLogicalGuardNanoseconds'] for key in CATEGORIES[-2:])
            require(guard <= total and wire <= total and nested <= guard, 'Counters exceed their request interval')
            for key in CATEGORIES:
                require(rows[key]['count'] <= cohort[key]['count']
                        and rows[key]['nanoseconds'] <= cohort[key]['nanoseconds'], 'Request exceeds cohort counter')
            if mode == 'full':
                require(wire == nested == count('wireSendCompleted') == count('wireReceiveCompleted') == 0,
                        'Solo claims wire activity')
            if not sample['warmup']:
                phases[name].append(dict(durationNanoseconds=total, logicalGuardNanoseconds=guard,
                    osSnapshotNanoseconds=rows['osSnapshot']['nanoseconds'],
                    wireNanoseconds=wire, wireNestedGuardNanoseconds=nested,
                    wireRemainderNanoseconds=wire-nested,
                    counts={key: row['count'] for key, row in rows.items()}))
    summary = {}
    for name, samples in phases.items():
        require(len(samples) == 3, 'Measured counter cohort incomplete')
        summed = {key: sum(sample[key] for sample in samples) for key in samples[0] if key != 'counts'}
        summary[name] = dict(summed, logicalGuardFraction=summed['logicalGuardNanoseconds']/summed['durationNanoseconds'],
                             counts={key: sum(sample['counts'][key] for sample in samples) for key in CATEGORIES})
    return dict(mode=mode, retainedEvidence=joined, phases=summary,
                performance=original.summarize(value['samples'], value['job']['promptCount'], value['job']['outputCount']))


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('case', type=Path)
    parser.add_argument('kind', choices=['solo', 'pair'])
    parser.add_argument('--expect-native', required=True)
    parser.add_argument('--observation-policy', choices=['repeated', 'invocation'], required=True)
    args = parser.parse_args()
    selected = [('full', 'darkbloom-48')] if args.kind == 'solo' else [('stage0', 'darkbloom-24'), ('stage1', 'darkbloom-48')]
    rows = [role(args.case, args.kind, mode, host, args.expect_native, args.observation_policy) for mode, host in selected]
    output = args.case / args.kind / 'guard-analysis.json'
    report = dict(schema='gemma4_guard_observation_analysis_v1', status='passed',
        nativeSHA256=args.expect_native, observationPolicy=args.observation_policy, roles=rows,
        categoriesAreInclusive=True, wireRemainderIncludesPeerWorkAndSynchronization=True,
        pureLinkLatencyMeasured=False, numericalComparisonIsSeparate=True,
        sourceSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    with output.open('x') as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
    print(json.dumps(dict(status='passed', output=str(output), roles=[dict(mode=row['mode'],
        performance=row['performance'], guardFractions={key: value['logicalGuardFraction'] for key, value in row['phases'].items()}) for row in rows])))


if __name__ == '__main__':
    main()
