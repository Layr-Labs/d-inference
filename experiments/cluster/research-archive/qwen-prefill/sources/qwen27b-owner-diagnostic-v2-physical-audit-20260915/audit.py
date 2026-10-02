"""Read-only replay of failed diagnostic attempt79222; no process/network calls."""
from pathlib import Path
from decimal import Decimal
import base64
import hashlib
import json
import re

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
PARENT = ROOT / 'qwen27b-owner-native-diagnostic-rerun-v2-20260915'
RUN = PARENT / 'physical-1'
OUT = Path(__file__).resolve().parent
seen = {}


def raw(path):
    value = path.read_bytes()
    assert len(value) <= 16 * 1024 * 1024
    seen[str(path)] = {'path': str(path), 'bytes': len(value), 'sha256': hashlib.sha256(value).hexdigest()}
    return value


def pairs(items):
    result = {}
    for key, value in items:
        assert key not in result
        result[key] = value
    return result


def parse(value):
    return json.loads(value, object_pairs_hook=pairs)


def read(path):
    return parse(raw(path))


def lines(path):
    value = raw(path)
    assert value.endswith(b'\n')
    return [parse(line) for line in value.splitlines() if line.strip()]


def main():
    execution = read(RUN / 'execution.json')
    controller = lines(RUN / 'controller.stdout.jsonl')
    assert len(controller) == 2
    started, result = controller
    config_raw = raw(PARENT / 'configuration/controller.json')
    config = parse(config_raw)
    config_sha = hashlib.sha256(config_raw).hexdigest()
    assert config_sha == 'a0393bcdc8d3e359cc7d58f7d75a88df18c32020b7bd731f6fc22aaaad2f812e'
    assert started['schema'] == 'owner_qualification_started_v1' and result['schema'] == 'owner_qualification_result_v1'
    assert started['configurationSHA256'] == result['configurationSHA256'] == config_sha
    assert started['membershipEpoch'] == config['membershipEpoch'] == '47f2807c-2238-4bd0-86f2-5980211b3b99'
    assert started['requestID'] == config['requestID'] == '20801ced-ca29-4faf-b71a-9ebbe1886a14'
    assert result['completed'] is False and result['tokenIDs'] == [] and result['failure'] == 'closed'
    assert result['nativeCleanupObserved'] == result['ownerDeviceLeaseReleasedObserved'] == [True, True]
    assert [base64.b64decode(value, validate=True) for value in result['endpointDiagnosticsBase64']] == [b'', b'']
    for rank in (0, 1):
        assert raw(RUN / ('owner-' + str(rank) + '.diagnostics.raw')) == b''
    assert raw(RUN / 'controller.stderr') == b''
    resources = []
    for rank in (0, 1):
        values = lines(RUN / ('resources-' + str(rank) + '.jsonl'))
        assert values and len(values) <= 1400
        free_values, sample_spans, pressures = [], [], []
        previous_end = 0
        for ordinal, value in enumerate(values):
            assert value['schema'] == 'native_owner_resource_observation_v1' and value['ordinal'] == ordinal
            vm, memory, power = value['rawVMStat'], value['rawMemory'], value['rawPower']
            page = re.search(r'page size of (\d+) bytes', vm)
            count = re.search(r'Pages free:\s+(\d+)\.', vm)
            swap = re.search(r'used\s*=\s*([0-9.]+)([MG])', memory)
            assert page and count and swap
            free = int(page[1]) * int(count[1])
            pressure = int(memory.splitlines()[0])
            swap_bytes = Decimal(swap[1]) * (1024 ** 2 if swap[2] == 'M' else 1024 ** 3)
            ac = "Now drawing from 'AC Power'" in power
            assert type(value['actualFreeBytes']) is int and value['actualFreeBytes'] == free >= 6 * 1024 ** 3
            assert pressure == value['pressureLevel'] and 0 <= pressure <= 2
            assert swap_bytes == Decimal(value['reportedSwapBytes']) == 0
            assert value['acPower'] is ac is True and value['admissible'] is True
            begin, end = value['startedMonotonicNS'], value['completedMonotonicNS']
            assert type(begin) is int and type(end) is int and previous_end <= begin <= end
            assert end - begin <= 10 * 10 ** 9
            previous_end = end
            free_values.append(free); sample_spans.append(end - begin); pressures.append(pressure)
        assert raw(RUN / ('resources-' + str(rank) + '.stderr')) == b''
        resources.append({'rank': rank, 'samples': len(values), 'minimumActualFreeBytes': min(free_values),
            'minimumActualFreeGiB': min(free_values) / 1024 ** 3, 'pressureLevels': sorted(set(pressures)),
            'allAC': True, 'allReportedSwapBytesZero': True, 'allObservedResourceGatesPass': True,
            'maximumSampleDurationNanoseconds': max(sample_spans)})
    postflight = lines(RUN / 'postflight-observations.jsonl')
    assert len(postflight) == 2 and [row['rank'] for row in postflight] == [0, 1]
    for row in postflight:
        assert row['active'] == [] and row['journalBytes'] == 0
        assert row['journalSHA256'] == hashlib.sha256(b'').hexdigest()
    assert execution['controllerExitCode'] == 1 and execution['pinsUnchanged'] is True
    assert execution['localController']['exitCode'] == 1 and execution['localController']['reaped'] is True
    assert execution['localController']['groupAbsent'] is True and execution['localController']['killedOwnedGroup'] is False
    assert execution['nativeProcessesAbsent'] is execution['journalsEmpty'] is True
    assert execution['monitors'] == [{'exitCode': 0, 'errors': []}, {'exitCode': 0, 'errors': []}]
    assert execution['remoteCleanup']['ownershipWindowExpired'] is False
    assert execution['remoteCleanup']['observationErrors'] == []
    assert execution['leaseExitCode'] == 0 and execution['runCompletedAndAliasRestored'] is False
    lease, = lines(RUN / 'lease.stdout.tail.jsonl')
    assert lease == execution['leaseFinal'][0] and lease['restored'] is True
    assert lease['before']['en1'] == lease['afterRemove']['en1']
    assert lease['address'] not in lease['before']['en1'] and lease['address'] in lease['afterAdd']['en1']
    assert raw(RUN / 'lease.stderr') == b''
    # Rehash exact source/run pins independently; no source or binary is executed.
    pins = read(PARENT / 'run-pins.json')['files']
    for item in pins:
        value = raw(Path(item['path']))
        assert len(value) == item['bytes'] and hashlib.sha256(value).hexdigest() == item['sha256']
    report = {'schema': 'qwen27b_failed_diagnostic_physical_audit_v1', 'auditPassed': True,
        'requestOutcome': 'failed before any token; native cause not observable in retained empty diagnostics',
        'actualNativeCleanupObserved': [True, True], 'authenticatedOwnerReleaseACKs': [True, True],
        'diagnosticBytes': [0, 0], 'resources': resources,
        'naturalControllerExitCode': 1, 'controllerReapedAndGroupAbsent': True, 'forcedControllerKill': False,
        'postflightObservedNativeOwnerProcesses': [[], []], 'postflightJournalBytes': [0, 0],
        'aliasRestoredWithMatchingBeforeAfterInterface': True, 'runPinsVerified': len(pins),
        'parentElapsedSeconds': execution['elapsedSeconds'], 'performanceClaim': False,
        'limits': ['Resource samples are discrete observations, not a proof of the native internal load gate.',
                   'No model numerical result, no successful inference and no native refusal cause are established.',
                   'Sampler clocks are compared within each process only; no cross-process uptime comparison.',
                   'Authenticated cleanup/ACK evidence remains separate from observed process/journal absence.'],
        'inputs': list(seen.values()), 'compilerModelOrRemoteExecution': False}
    for item in seen.values():
        value = Path(item['path']).read_bytes()
        assert len(value) == item['bytes'] and hashlib.sha256(value).hexdigest() == item['sha256']
    (OUT / 'review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'auditPassed': True, 'requestOutcome': 'failed', 'resources': resources,
                      'reviewSHA256': hashlib.sha256((OUT / 'review.json').read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()
