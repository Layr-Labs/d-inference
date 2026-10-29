"""Replay retained native output and independent OS/ownership receipts; never run GPU."""
import argparse
import hashlib
from pathlib import Path
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT/'package'))
from allocation_result import CASES, validate_result
from binding_common import integer, parse, require, same
from binding_inputs import snapshot
from mtp_journal import require_empty
from reference_resources import sample_local, validate_local
from target_contract import ARTIFACT, JOBS, REMOTE


def read(path, cap):
    require(path.is_file() and not path.is_symlink() and path.parent.resolve() == path.parent, 'Unsafe returned evidence path')
    return snapshot(path, cap, empty=True)['raw']


def validate(directory, case_id, attempt, package_sha):
    require(ARTIFACT['status'] == 'bound_passed_build' and case_id in CASES, 'Unbound allocation case')
    integer(attempt, 'attempt', 1, 9)
    expected_files = {'host.json', 'input-binding.json', 'journal-preflight.json', 'journal-postflight.json',
        'owner.json', 'processes-preflight.json', 'processes-postflight.json', 'resources.jsonl', 'terminal.json',
        'native/worker-0.stdin', 'native/worker-0.stdout', 'native/worker-0.stderr'}
    paths = list(directory.rglob('*'))
    require(not any(path.is_symlink() for path in paths), 'Returned tree contains a link')
    require({str(path.relative_to(directory)) for path in paths if path.is_file()} == expected_files,
            'Returned evidence closure differs')
    def value(name): return parse(read(directory/name, 1_048_576))
    host, binding, terminal, owner = (value(name) for name in ('host.json', 'input-binding.json', 'terminal.json', 'owner.json'))
    same(binding['packageSHA256'], package_sha, 'package identity')
    same(binding['fixture'], case_id, 'case binding')
    same(binding['nativeSHA256'], ARTIFACT['nativeSHA256'], 'native identity')
    same(binding['bundleSHA256'], ARTIFACT['bundleSHA256'], 'bundle identity')
    same(binding['sourceSnapshotSHA256'], ARTIFACT['sourceSnapshotSHA256'], 'source identity')
    same(binding['resourceProfileQualified'], False, 'not a serving profile')
    same(host['expectedSSHTarget'], 'developer@192.0.2.250', '24 GiB target')
    same(host['machine'], 'arm64', 'native architecture')
    stdout = read(directory/'native/worker-0.stdout', 65_537)
    require(stdout.endswith(b'\n') and stdout.count(b'\n') == 1, 'Expected one complete native JSONL record')
    same(read(directory/'native/worker-0.stderr', 1_048_576), b'', 'native stderr empty')
    same(read(directory/'native/worker-0.stdin', 1_048_576), b'', 'no native input stream')
    report = validate_result(stdout[:-1], case_id, host)
    same(terminal['nativeResult'], report, 'terminal retains exact native report')
    same(terminal['schema'], 'collective_allocation_native_observation_v1', 'terminal schema')
    same(terminal['fixture'], case_id, 'terminal case')
    same(terminal['status'], 'completed', 'terminal completion')
    for key in ('primaryFailure',): same(terminal[key], None, key)
    for key in ('postflightErrors', 'cleanupErrors'): same(terminal[key], [], key)
    for key in ('nativeLeaderReaped', 'ownedGroupsAbsent', 'outputComplete', 'sourceInputsUnchanged',
                'journalEmptyAfterExit', 'processInventoryClear', 'nativeAllocationExecutionObserved'):
        same(terminal[key], True, key)
    for key in ('watchdogExpired', 'fabricatedTargetWeights', 'modelTrunkExecutionObserved',
                'registeredCheckpointExecution', 'bilateralVerification', 'windowStateExecutionObserved',
                'sharedTargetTransactionObserved', 'registeredProfileExecution', 'throughputMeasurementValid',
                'protocolOwnerLeaseReleaseObserved', 'journalMutationPerformed', 'rdmaExecutionObserved', 'protectedServingEnabled'):
        same(terminal[key], False, key)
    same(terminal['nativeExitCodes'], [0], 'natural native exit')
    require(type(terminal['elapsedSeconds']) in (int, float) and 0 < terminal['elapsedSeconds'] < 90,
            'Original parent budget exceeded')
    require(type(owner['nativePIDs']) is list and len(owner['nativePIDs']) == 1, 'One fresh native process required')
    pid = integer(owner['nativePIDs'][0], 'owned native PID', 1)
    same(owner['nativePGIDs'], [pid], 'owned native process group')
    same(terminal['nativePIDs'], [pid], 'terminal native PID')
    same(terminal['owned_group_observation'], [dict(ownedPID=pid, ownedPGID=pid, absent=True)], 'actual post-reap group absence')
    same(owner['nativeArgv'], [REMOTE+'/bundle/CollectiveAllocationCheck', 'run-resource-case', case_id], 'exact native argv')
    same(owner['nativeAlarmSeconds'], 60, 'native alarm')
    integer(owner['remainingGroupWatchdogSeconds'], 'group watchdog', 61, 90)
    remote_run = REMOTE+'/runs/'+case_id+'-'+str(attempt)
    expected_streams = []
    for stream in ('stderr', 'stdin', 'stdout'):
        raw = read(directory/('native/worker-0.'+stream), 1_048_576)
        expected_streams.append(dict(worker=0, stream=stream, path=remote_run+'/native/worker-0.'+stream,
            bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
    same(terminal['retained_streams'], expected_streams, 'retained native streams')
    before, after = value('journal-preflight.json'), value('journal-postflight.json')
    require_empty(before); require_empty(after, before)
    same(before['path'], '/Users/developer/.darkbloom/cluster-device/native-device.lease', 'canonical journal')
    for journal in (before, after):
        same(journal['exclusiveObservationLockAcquired'], True, 'actual exclusive journal observation')
        same(journal['journalMutationPerformed'], False, 'no journal repair')
    for name in ('processes-preflight.json', 'processes-postflight.json'):
        same(value(name)['prohibited'], [], 'actual process inventory empty')
    same(terminal['postflight']['journal'], after, 'postflight journal receipt')
    same(terminal['postflight']['processObservation'], value('processes-postflight.json'), 'postflight process receipt')
    resources = [parse(line) for line in read(directory/'resources.jsonl', 1_048_576).splitlines()]
    require(2 <= len(resources) <= 2000 and resources[0]['phase'] == 'prelaunch'
            and resources[-1]['phase'] == 'postflight', 'Complete resource observation required')
    previous = 0
    for row in resources:
        validate_local(row)
        same(row['pressureLevel'], 1, 'normal memory pressure')
        require(row['startedMonotonicNS'] >= previous, 'Resource observations went backwards')
        previous = row['completedMonotonicNS']
        def replay(command):
            return row['rawVMStat'] if command[0] == '/usr/bin/vm_stat' else row['rawPower'] if command[0] == '/usr/bin/pmset' else row['rawMemory']
        parsed = sample_local(read=replay)
        for key in ('actualFreeBytes', 'pressureLevel', 'reportedSwapBytes', 'acPower'):
            same(row[key], parsed[key], 'raw OS replay '+key)
    require(resources[-1]['completedMonotonicNS']-resources[0]['startedMonotonicNS'] < 90*10**9,
            'Resource observation exceeded original parent budget')
    return dict(caseID=case_id, passed=True, actualNativeCleanup=True, standaloneGateCleanup=True,
        resourceSamples=len(resources), minimumActualFreeBytes=min(row['actualFreeBytes'] for row in resources),
        nativePeakIncrementBytes=report['observedPeakNativeActiveBytes']-report['baselineNativeActiveBytes'],
        physicalPeakIncrementBytes=report['conservativeObservedPhysicalIncrementBytes'],
        rdmaMeasured=False, modelExecuted=False, protectedServingEnabled=False, profileQualified=False)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--case', choices=sorted(CASES), required=True)
    parser.add_argument('--attempt', type=int, choices=range(1, 10), default=1)
    parser.add_argument('--package-sha256', required=True)
    args = parser.parse_args()
    import json
    print(json.dumps(validate(args.directory.resolve(), args.case, args.attempt, args.package_sha256), sort_keys=True))


if __name__ == '__main__': main()
