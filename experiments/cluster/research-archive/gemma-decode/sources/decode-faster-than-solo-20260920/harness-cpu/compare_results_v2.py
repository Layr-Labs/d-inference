"""Read-only replay of completed cohorts with retained process/evidence joins."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).resolve().parent
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
    job = value['job']; prefill_count = (job['promptCount'] + job['chunkSize'] - 1) // job['chunkSize']
    expected_frames = prefill_count + job['outputCount'] - 1
    interval(value['loadStartedNanoseconds'], value['loadCompletedNanoseconds'], 'Native loading')
    interval(value['loadCompletedNanoseconds'], value['probeCompletedNanoseconds'], 'Native probe')
    previous = value['probeCompletedNanoseconds']
    total_frames = 0
    for sample in value['samples']:
        start, end = sample['startedNanoseconds'], sample['completedNanoseconds']
        interval(start, end, 'Native request')
        require(previous <= start and sample['timingsAreSameProcess'] is True
                and sample['clockAcrossHostsCompared'] is False
                and sample['evidenceOutsideTimedPath'] is True and sample['mtpEnabled'] is False,
                'Request clock scope/order differs')
        previous = end
        agreements = sample['tokenAgreementNanoseconds']
        require(len(agreements) == job['outputCount'] and start < agreements[0]
                and agreements[-1] <= end, 'Token agreement lies outside its request')
        for tick in agreements:
            integer(tick, 'Token agreement')
        frames = sample['frames']; require(len(frames) == expected_frames, 'Missing native frames')
        frame_end = start; selected_frames = []
        for sequence, frame in enumerate(frames):
            prefill = sequence < prefill_count
            offset = sequence * job['chunkSize'] if prefill else job['promptCount'] + sequence - prefill_count
            count = min(job['chunkSize'], job['promptCount'] - offset) if prefill else 1
            require(frame['sequence'] == sequence and frame['phase'] == ('prefill' if prefill else 'decode')
                    and frame['offset'] == offset and frame['tokenCount'] == count, 'Native frame geometry/order differs')
            a, b = frame['startedNanoseconds'], frame['completedNanoseconds']
            interval(a, b, 'Native frame')
            require(frame_end <= a <= b <= end, 'Native frame clock leaves its request')
            phases = frame['ownerPhases']
            require([p['name'] for p in phases] == list(PHASES), 'Owner phase order differs')
            phase_end = a
            for index, phase in enumerate(phases):
                tick = integer(phase['timestampNanoseconds'], 'Owner phase')
                require(phase_end <= tick <= b and phase['tokenCount'] == count
                        and phase['committedTokens'] == offset + (count if index == len(PHASES)-1 else 0),
                        'Owner phase clock/frontier differs')
                phase_end = tick
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


def compare(case):
    for name, wanted in SOURCE_PINS.items():
        require(sha(raw(ROOT / name)) == wanted, 'Reviewed comparison dependency changed')
    prior_path = case / 'comparison.json'
    prior = raw(prior_path) if prior_path.exists() else None
    joins = [join_role(case, kind, mode, host) for kind, mode, host in
             [('solo', 'full', 'darkbloom-48'), ('pair', 'stage0', 'darkbloom-24'),
              ('pair', 'stage1', 'darkbloom-48')]]
    # Replays original row/state hashes, all request IDs, original job/SSH joins,
    # independent raw pressure/free/swap/AC parsing, and same-process TPS math.
    report = original.compare(case)
    if prior is not None:
        require(decode(prior) == report and raw(prior_path) == prior, 'Original comparison changed or is inconsistent')
    report.update(schema='gemma4_matched_resident_comparison_v2', retainedEvidenceJoins=joins,
                  originalComparisonSHA256=sha(prior) if prior is not None else None,
                  comparisonSourceSHA256=sha(raw(Path(__file__))), dependencySHA256=SOURCE_PINS,
                  validationScope='completed fixed cohort; final row and final state per request',
                  intermediateRowsCompared=False, crossProcessClockOriginsJoined=False)
    for name, wanted in SOURCE_PINS.items():
        require(sha(raw(ROOT / name)) == wanted, 'Comparison dependency changed during replay')
    return report


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('case', type=Path)
    args = parser.parse_args(); report = compare(args.case)
    destination = args.case / 'comparison-v2.json'
    with destination.open('x') as stream:
        json.dump(report, stream, indent=2, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status=report['status'], output=str(destination),
                         sha256=sha(raw(destination)), fullRowsCompared=report['fullRowsCompared'],
                         stateComponentsCompared=report['stateComponentsCompared'],
                         resourceSamples=[x['resourceSamples'] for x in report['retainedEvidenceJoins']])))


if __name__ == '__main__':
    main()
