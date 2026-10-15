"""Read-only five-role serial/lookahead replay; complete physical cohorts only."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'package'))
import compare_results as original
from jaccl_startup_stderr import validate_retained

require = original.require
EMPTY_SHA = hashlib.sha256(b'').hexdigest()
SOURCE_PINS = {
    'compare_results.py': 'f2fe4c335636deb3d6b5938c3ac92cb17aae141f98328702609b7e64dcd856b1',
    'package/jaccl_startup_stderr.py': '42c7f01b36392cb69cf177081fd6cf7a953963fd7cfb92b27ca0e784a5b82f29',
}
PHASES = ('graphConstruction.begin', 'graphConstruction.end', 'rootStaging.begin',
          'rootStaging.end', 'evaluation.begin', 'evaluation.end',
          'validationCommit.begin', 'validationCommit.end')
JOURNAL_ID = ('path', 'directoryDevice', 'directoryInode', 'fileDevice', 'fileInode')
RESOURCE_KEYS = {'phase', 'startedMonotonicNS', 'completedMonotonicNS', 'timestampUTC',
                 'actualFreeBytes', 'pressureLevel', 'reportedSwapBytes', 'acPower',
                 'rawVMStat', 'rawMemory', 'rawPower'}


def raw(path, bound=32 * 1024**2 + 1):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and 0 <= info.st_size <= bound,
            'Retained file is not a bounded ordinary file: ' + str(path))
    return path.read_bytes()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def decode(data):
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate retained JSON key')
            result[key] = value
        return result
    def invalid_constant(_):
        raise ValueError('Nonfinite retained JSON number')
    return json.loads(data, object_pairs_hook=object_pairs, parse_constant=invalid_constant)


def read(path, bound=32 * 1024**2 + 1):
    return decode(raw(path, bound))


def integer(value, label):
    require(type(value) is int and value >= 0, label + ' is not an unsigned integer')
    return value


def interval(start, end, label, maximum=None):
    integer(start, label); integer(end, label)
    require(start <= end, label + ' runs backwards')
    require(maximum is None or end - start <= maximum, label + ' exceeds its bound')


def journal(value, initial=None):
    require(set(value) == set(JOURNAL_ID) | {'bytes', 'sha256', 'exclusiveObservationLockAcquired',
                                         'journalMutationPerformed'}, 'Journal schema differs')
    require(value['path'] == '/Users/developer/.darkbloom/cluster-device/native-device.lease'
            and value['bytes'] == 0 and value['sha256'] == EMPTY_SHA
            and value['exclusiveObservationLockAcquired'] is True
            and value['journalMutationPerformed'] is False, 'Canonical journal is not observed empty')
    for name in JOURNAL_ID[1:]:
        require(integer(value[name], name) > 0, 'Journal identity is missing')
    if initial is not None:
        require(all(value[key] == initial[key] for key in JOURNAL_ID), 'Canonical journal inode changed')


def processes(value):
    require(set(value) == {'command', 'observedStartMonotonicNS', 'observedEndMonotonicNS',
                          'observerPID', 'processCount', 'prohibited', 'stdoutSHA256'},
            'Process observation schema differs')
    require(value['command'] == ['/bin/ps', '-Aww', '-o', 'pid=,uid=,comm=']
            and value['prohibited'] == [] and integer(value['processCount'], 'processCount') > 0
            and integer(value['observerPID'], 'observerPID') > 0,
            'Native/owner absence was not observed')
    require(type(value['stdoutSHA256']) is str and len(value['stdoutSHA256']) == 64
            and all(c in '0123456789abcdef' for c in value['stdoutSHA256']), 'Process output digest differs')
    interval(value['observedStartMonotonicNS'], value['observedEndMonotonicNS'],
             'Read-only process observation', 4_000_000_000)


def resource_clock(rows):
    require(2 <= len(rows) <= 2000, 'Resource sampling count is outside the supervisor bound')
    require(rows[0]['phase'] == 'prelaunch' and rows[-1]['phase'] == 'postflight'
            and sum(x['phase'] == 'prelaunch' for x in rows) == 1
            and sum(x['phase'] == 'postflight' for x in rows) == 1,
            'Missing or repeated initial/final resource checks')
    previous = 0
    for row in rows:
        require(set(row) == RESOURCE_KEYS, 'Raw resource schema differs')
        start, end = row['startedMonotonicNS'], row['completedMonotonicNS']
        interval(start, end, 'Resource observation', 10_000_000_000)
        require(previous <= start, 'Resource observation sequence overlaps or runs backwards')
        previous = end
    return rows[-1]['completedMonotonicNS'] - rows[0]['startedMonotonicNS']


def request_clocks(value):
    job = value['job']; policy = job.get('prefillPolicy', 'serial')
    require(policy in ('serial', 'oneChunkLookahead')
            and (job['mode'] != 'full' or policy == 'serial'), 'Prefill policy is invalid')
    producer = policy == 'oneChunkLookahead' and job['mode'] == 'stage0'
    prefill_count = (job['promptCount'] + job['chunkSize'] - 1) // job['chunkSize']
    expected_frames = prefill_count + job['outputCount'] - 1
    interval(value['loadStartedNanoseconds'], value['loadCompletedNanoseconds'], 'Native loading')
    interval(value['loadCompletedNanoseconds'], value['probeCompletedNanoseconds'], 'Native probe')
    previous = value['probeCompletedNanoseconds']; total_frames = 0
    for sample in value['samples']:
        start, end = sample['startedNanoseconds'], sample['completedNanoseconds']
        interval(start, end, 'Native request')
        require(previous <= start and sample['timingsAreSameProcess'] is True
                and sample['clockAcrossHostsCompared'] is False
                and sample['evidenceOutsideTimedPath'] is True and sample['mtpEnabled'] is False
                and sample['durationIncludesResourceChecksAndSerialTransport'] == (policy == 'serial'),
                'Request clock scope/order differs')
        previous = end
        if job['mode'] != 'full' and 'prefillPolicy' in job:
            expected_summary = dict(policy=policy, rank=0 if job['mode'] == 'stage0' else 1,
                preparedAheadFrames=prefill_count-1 if producer else 0,
                maximumPreparedBoundaries=1 if producer else 0,
                pendingConsumedAtCompletion=0, decodePrefetchCount=0)
            require(sample.get('prefillSummary') == expected_summary, 'Actual prefill drain/slot summary differs')
        else:
            require('prefillSummary' not in sample, 'Default/full policy unexpectedly reports a producer')
        agreements = sample['tokenAgreementNanoseconds']
        require(len(agreements) == job['outputCount'] and start < agreements[0]
                and agreements[-1] <= end, 'Token agreement lies outside its request')
        for tick in agreements:
            integer(tick, 'Token agreement')
        frames = sample['frames']; require(len(frames) == expected_frames, 'Missing native frames')
        frame_end = owner_end = start; selected_frames = []
        for sequence, frame in enumerate(frames):
            prefill = sequence < prefill_count
            offset = sequence * job['chunkSize'] if prefill else job['promptCount'] + sequence - prefill_count
            count = min(job['chunkSize'], job['promptCount'] - offset) if prefill else 1
            require(frame['sequence'] == sequence and frame['phase'] == ('prefill' if prefill else 'decode')
                    and frame['offset'] == offset and frame['tokenCount'] == count, 'Native frame geometry/order differs')
            a, b = frame['startedNanoseconds'], frame['completedNanoseconds']
            interval(a, b, 'Native frame')
            require(start <= a <= b <= end and frame_end <= b, 'Native frame clock leaves its request/order')
            if producer and prefill and sequence > 0:
                # Exactly one later preparation is allowed while the previous
                # frame awaits consumption. k+2 cannot start before k completes.
                floor = frames[sequence-2]['completedNanoseconds'] if sequence > 1 else start
                require(floor <= a and owner_end <= a <= frame_end,
                        'Prepared prefill exceeds one slot or does not precede prior ACK completion')
            else:
                require(frame_end <= a, 'Serial/decode frame overlaps prior completion')
            phases = frame['ownerPhases']
            require([p['name'] for p in phases] == list(PHASES), 'Owner phase order differs')
            phase_end = a
            for index, phase in enumerate(phases):
                tick = integer(phase['timestampNanoseconds'], 'Owner phase')
                require(phase_end <= tick <= b and phase['tokenCount'] == count
                        and phase['committedTokens'] == offset + (count if index == len(PHASES)-1 else 0),
                        'Owner phase clock/frontier differs')
                phase_end = tick
            require(owner_end <= phases[0]['timestampNanoseconds'], 'Two local owner forwards overlap')
            if producer and prefill and sequence > 0:
                require(phase_end <= frame_end, 'Prepared next frame did not commit before prior ACK completed')
            owner_end = phase_end
            if not prefill or sequence == prefill_count - 1:
                selected_frames.append(frame)
            frame_end = b
        for tick, frame in zip(agreements, selected_frames):
            require(frame['ownerPhases'][-1]['timestampNanoseconds'] <= tick <= frame['completedNanoseconds'],
                    'Token agreement does not follow its own committed frame')
        first = sample.get('firstLogitsNanoseconds')
        if job['mode'] == 'stage0':
            require(first is None, 'Stage0 incorrectly claims local logits')
        else:
            integer(first, 'First native logits')
            first_frame = selected_frames[0]
            require(first_frame['ownerPhases'][-1]['timestampNanoseconds'] <= first <= agreements[0],
                    'First logits clock is outside the first selected frame')
        total_frames += len(frames)
    return total_frames


def join_role(case, kind, mode, host):
    folder = case / kind / mode; outer = read(case / kind / 'receipt.json')
    terminal_bytes = raw(folder / 'terminal.json'); terminal = decode(terminal_bytes)
    require(terminal['schema'] == 'gemma4_benchmark_terminal_v1' and terminal['mode'] == mode
            and terminal['primaryFailure'] is None, 'Terminal schema/failure differs')
    require(not outer.get('cancellationErrors') and not outer.get('peerCancellations'),
            'A cancelled cohort cannot be accepted')
    stdout = raw(folder / 'native/worker-0.stdout')
    require(stdout.endswith(b'\n') and stdout.count(b'\n') == 1,
            'Retained native stdout must be one complete LF-terminated result')
    require(decode(stdout[:-1]) == terminal['result'], 'Retained native stdout differs from actual terminal result')
    stderr = raw(folder / 'native/worker-0.stderr', 1024)
    stderr_policy = validate_retained(stderr, mode)
    require(mode != 'stage1' or terminal.get('startupStderr') == stderr_policy,
            'Retained stage1 stderr summary differs')
    before = read(folder / 'journal-before.json', 16_384)
    after = read(folder / 'journal-after.json', 16_384)
    journal(before); journal(after, before)
    observed = [row['observed'] for row in outer['quiescence'] if row['host'] == host]
    require(len(observed) == 1, 'Missing unique host quiescence')
    journal(observed[0]['journal'], before); processes(observed[0]['processes'])
    gate = read(folder / 'gate.json', 16_384); owner = read(folder / 'owner.json', 16_384)
    require(all(gate[key] == before[key] for key in JOURNAL_ID) and gate['bytes'] == 0
            and gate['exclusiveLockHeld'] is True and gate['inheritedAcrossExec'] is True
            and gate['journalMutationPerformed'] is False, 'Native inherited canonical lease differs')
    processes(gate['processObservation'])
    pids = terminal['nativePIDs']
    require(len(pids) == 1 and integer(pids[0], 'Native PID') > 0
            and owner['nativePIDs'] == owner['nativePGIDs'] == pids
            and gate['ownerPID'] == pids[0], 'Owned native process identities differ')
    rows = [decode(line) for line in raw(folder / 'resources.jsonl', 16 * 1024**2).splitlines()]
    span = resource_clock(rows)
    elapsed = terminal['elapsedSeconds']
    require(type(elapsed) in (int, float) and math.isfinite(elapsed) and 0 < elapsed < 315
            and span / 1e9 <= elapsed, 'Parent resource interval exceeds actual terminal lifetime')
    frames = request_clocks(terminal['result'])
    return dict(mode=mode, nativePID=pids[0], terminalSHA256=sha(terminal_bytes),
                stdoutSHA256=sha(stdout), stderrSHA256=sha(stderr), stderrPolicy=stderr_policy,
                nativeFramesChecked=frames, resourceSamples=len(rows),
                minimumActualFreeBytes=min(row['actualFreeBytes'] for row in rows),
                sameCanonicalJournal=True, nativeStdoutMatchesTerminal=True,
                nativeAndParentClocksCompared=False, rawProcessTableRetained=False)


def budget_delta(serial, lookahead):
    """Require the additional charge on top of identical retained named terms."""
    base, added = serial['resources'], lookahead['resources']
    job = lookahead['job']; rank = 0 if job['mode'] == 'stage0' else 1
    require('prefillAllowance' not in base, 'Serial unexpectedly reserves a lookahead policy')
    for value in (base, added):
        require(value['actualAllocatorBoundsUsed'] is True and value['operationalResourceChecksApplied'] is True
                and value['reclaimableUsedForAdmission'] is False
                and value['minimumActualFreeBytes'] >= 6 * 1024**3
                and value['selectedTensorCount'] == value['completedTensorCount']
                and value['observationCount'] > 0, 'Resource owner completion/authority differs')
        require(len(value['namedArrays']) == len(value['namedAllocationBounds'])
                and all(type(n) is int and n >= row['bytes'] > 0
                        for row, n in zip(value['namedArrays'], value['namedAllocationBounds']))
                and value['namedNativeReserveBytes'] == sum(value['namedAllocationBounds']),
                'Named native allocation sum differs')
    for name in ('policy', 'planSHA256', 'requestSHA256', 'selectedTensorCount',
                 'selectedAllocationBounds', 'persistentCastLogicalBytes', 'stateLogicalBytes'):
        require(base[name] == added[name], 'Serial/lookahead non-policy resource term differs')
    allowance = added.get('prefillAllowance')
    require(type(allowance) is dict and set(allowance) == {'rank', 'extraNativeBytes', 'extraHostBytes'}
            and allowance['rank'] == rank, 'Lookahead lacks the actual extra reservation')
    logical = job['chunkSize'] * 2816 * 4 if rank == 0 and job['promptCount'] > job['chunkSize'] else 0
    if logical:
        require(added['namedArrays'] == base['namedArrays'] + [dict(name='lookaheadPreparedBoundary', bytes=logical)]
                and added['namedAllocationBounds'][:-1] == base['namedAllocationBounds']
                and allowance['extraNativeBytes'] == added['namedAllocationBounds'][-1] >= logical,
                'Lookahead prepared boundary is not a distinct bounded native term')
    else:
        require(added['namedArrays'] == base['namedArrays']
                and added['namedAllocationBounds'] == base['namedAllocationBounds']
                and allowance['extraNativeBytes'] == 0, 'Receiver/single-chunk native terms changed')
    require(allowance['extraHostBytes'] == logical + 65_536
            and added['hostEvidenceReserveBytes'] == base['hostEvidenceReserveBytes'] + allowance['extraHostBytes']
            and added['namedNativeReserveBytes'] == base['namedNativeReserveBytes'] + allowance['extraNativeBytes'],
            'Lookahead native/host allowance was not additionally charged')
    return allowance


def compare(serial_case, lookahead_case):
    for name, wanted in SOURCE_PINS.items():
        require(sha(raw(ROOT / name)) == wanted, 'Reviewed comparison dependency changed')
    roles = [(serial_case, 'solo', 'full', 'darkbloom-48'),
             (serial_case, 'pair', 'stage0', 'darkbloom-24'),
             (serial_case, 'pair', 'stage1', 'darkbloom-48'),
             (lookahead_case, 'pair', 'stage0', 'darkbloom-24'),
             (lookahead_case, 'pair', 'stage1', 'darkbloom-48')]
    require(serial_case.resolve() != lookahead_case.resolve(), 'Policy cohorts must have separate evidence directories')
    joins = []; values = []; paths = []
    for case, kind, mode, host in roles:
        original.validate_launch(case, kind, mode, host)
        joins.append(join_role(case, kind, mode, host))
        path = case / kind / mode; paths.append(path); values.append(original.load(path, mode))
    solo, serial0, serial1, overlap0, overlap1 = values; job = solo['job']
    require(job['captureEvidence'] is True, 'Lookahead numerical qualification requires actual full row/state capture')
    def workload(value):
        return {k:v for k,v in value['job'].items() if k not in ('mode', 'outputDirectory', 'prefillPolicy')}
    for value in values:
        require(workload(value) == workload(solo) and value['planSHA256'] == solo['planSHA256']
                and value['sourceLoad']['artifactSHA256'] == solo['sourceLoad']['artifactSHA256'],
                'Policy cohorts differ in request/build/artifact/Plan/workload')
    require(all(v['job'].get('prefillPolicy', 'serial') == 'serial' for v in values[:3])
            and all(v['job'].get('prefillPolicy') == 'oneChunkLookahead' for v in values[3:]),
            'Policy comparison does not bind serial and one-chunk lookahead')
    require(solo['scopeSHA256'] == serial0['scopeSHA256'] == serial1['scopeSHA256']
            and overlap0['scopeSHA256'] == overlap1['scopeSHA256']
            and overlap0['scopeSHA256'] != solo['scopeSHA256'], 'Policy must be bound into each distinct bilateral scope')
    allowances = [budget_delta(serial0, overlap0), budget_delta(serial1, overlap1)]
    rows = components = state_bytes = 0
    for ordinal, samples in enumerate(zip(*(v['samples'] for v in values))):
        require(all(s['selectedTokenIDs'] == samples[0]['selectedTokenIDs']
                    and s['requestSHA256'] == samples[0]['requestSHA256'] for s in samples),
                f'Generation/request differs at ordinal {ordinal}')
        full = decode(original.sidecar(paths[0], samples[0]['finalRow']))
        require(full['shape'] == [1, 262144] and len(full['values']) == 262144
                and all(math.isfinite(x) for x in full['values'])
                and full['values'].index(max(full['values'])) == samples[0]['selectedTokenIDs'][-1],
                'Full final row is invalid')
        full_state = original.state(paths[0], samples[0])
        require(set(full_state) == original.state_keys(0, 30), 'Full state key domain differs')
        for r0, r1 in ((1, 2), (3, 4)):
            require(decode(original.sidecar(paths[r1], samples[r1]['finalRow'])) == full,
                    f'Full final row differs at ordinal {ordinal}')
            a, b = [original.state(paths[n], samples[n]) for n in (r0, r1)]
            require(set(a) == original.state_keys(0, job['cut'])
                    and set(b) == original.state_keys(job['cut'], 30)
                    and not set(a) & set(b) and {**a, **b} == full_state,
                    f'Full native state differs at ordinal {ordinal}')
            rows += 1; components += len(full_state)
            state_bytes += sum(len(v[3]) for v in full_state.values())
    p, o = job['promptCount'], job['outputCount']
    timings = {name: original.summarize(v['samples'], p, o)
               for name, v in zip(('solo', 'serial0', 'serial1', 'lookahead0', 'lookahead1'), values)}
    for name, wanted in SOURCE_PINS.items():
        require(sha(raw(ROOT / name)) == wanted, 'Comparison dependency changed during replay')
    return dict(schema='gemma4_matched_lookahead_comparison_v1', status='passed',
        promptTokens=p, chunkSize=job['chunkSize'], outputTokens=o, cut=job['cut'], mtpEnabled=False,
        benchmarkNativeSHA256=job['buildIdentitySHA256'], artifactSHA256=solo['sourceLoad']['artifactSHA256'],
        fullRowsCompared=rows, stateComponentsCompared=components, stateBytesCompared=state_bytes,
        numericalEvidence='all generated IDs, complete final rows and native final state for both policies',
        timings=timings, actualAdditionalAllowance=allowances, retainedEvidenceJoins=joins,
        serialConservativePrefillTPS=min(timings['serial0']['prefillTPS'], timings['serial1']['prefillTPS']),
        lookaheadConservativePrefillTPS=min(timings['lookahead0']['prefillTPS'], timings['lookahead1']['prefillTPS']),
        comparisonSourceSHA256=sha(raw(Path(__file__))), dependencySHA256=SOURCE_PINS,
        captureOutsideTimedInterval=True, timingIncludesResourceChecks=True,
        transport='plaintext JACCL/RDMA', intermediateRowsCompared=False,
        crossProcessClockOriginsJoined=False, externalTTFTMeasured=False,
        representativeWorkloadStudyComplete=False)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('serial_case', type=Path); parser.add_argument('lookahead_case', type=Path)
    args = parser.parse_args(); report = compare(args.serial_case, args.lookahead_case)
    destination = args.lookahead_case / 'comparison-overlap.json'
    with destination.open('x') as stream:
        json.dump(report, stream, indent=2, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status=report['status'], output=str(destination), sha256=sha(raw(destination)),
                         fullRowsCompared=report['fullRowsCompared'], stateComponentsCompared=report['stateComponentsCompared'])))


if __name__ == '__main__':
    main()
