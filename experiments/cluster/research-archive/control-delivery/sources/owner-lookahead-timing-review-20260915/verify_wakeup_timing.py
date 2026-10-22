"""Independent retained-record joins and exact-rational timing arithmetic only."""
from pathlib import Path
from fractions import Fraction
from decimal import Decimal
import base64
import hashlib
import json
import re

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
OUTPUT = Path(__file__).resolve().parent
pins = {}


def raw(path):
    value = path.read_bytes()
    assert len(value) <= 16 * 1024 * 1024
    digest = hashlib.sha256(value).hexdigest()
    if str(path) in pins:
        assert pins[str(path)] == digest
    pins[str(path)] = digest
    return value


def obj(path):
    return json.loads(raw(path))


def lines(path):
    value = raw(path)
    assert value.endswith(b'\n')
    return [json.loads(line) for line in value[:-1].split(b'\n')]


def token_hash(values):
    return hashlib.sha256(','.join(map(str, values)).encode()).hexdigest()


comparison = obj(ROOT / 'owner-timing-wakeup-comparison-20260915/comparison.json')
correctness = obj(ROOT / 'owner-native-lookahead128-20260915/physical-1/comparison.json')
native = comparison['nativeBinarySHA256']
results, configurations, executions, all_ids = {}, [], [], []
for mode in ('serial', 'lookahead'):
    base = ROOT / ('owner-timing-' + mode + '-wakeup-20260915')
    output = base / 'physical-1'
    config = obj(base / 'configuration/controller.json'); configurations.append(config)
    execution = obj(output / 'execution.json'); executions.append(execution)
    records = lines(output / 'controller.stdout.jsonl'); result = records[-1]
    assert [r['schema'] for r in records] == ['owner_timing_cohort_started_v1'] + ['owner_timing_request_v1'] * 4 + ['owner_timing_cohort_result_v1']
    assert execution['controllerExitCode'] == execution['leaseExitCode'] == 0
    assert execution['runCompletedAndAliasRestored'] is True and execution['pinsUnchanged'] is True
    assert result['completed'] is True and result['nativeCleanupObserved'] == [True, True]
    assert result['ownerDeviceLeaseReleasedObserved'] == [True, True]
    assert result['clock'] == 'DispatchTime.uptimeNanoseconds.same_controller_process'
    for key in ('performanceQualification', 'fullNumericalComparisonPerformed', 'externalTTFTMeasured', 'providerCapacityUpdated', 'cpuQualification'):
        assert result[key] is False
    assert config['chunkSize'] == 512 and config['outputCount'] == 128
    assert config['warmupCount'] == 1 and config['measuredCount'] == 3
    assert config['lifetimeSeconds'] == 300 and config['requestSeconds'] == 120
    assert config['stopTokenIDs'] == [] and len(config['promptTokenIDs']) == 8192
    assert token_hash(config['expectedTokenIDs']) == correctness['selectedTokenIDsSHA256'] == result['expectedTokenIDsSHA256']
    assert token_hash(config['promptTokenIDs']) == result['promptTokenIDsSHA256']
    template = json.loads(base64.b64decode(config['readyTemplateBase64']))['ready']
    assert [v['buildSHA256'] for v in template['identity']['peers']] == [native] * 2
    owners = [obj(base / ('configuration/owner-rank%d.json' % rank)) for rank in (0, 1)]
    for owner in owners:
        assert owner['stageCut'] == 4
        assert owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'] == ('serial_v1' if mode == 'serial' else 'one_chunk_lookahead_v1')
    stamps = result['timestamps']
    assert stamps['controllerBegan'] <= stamps['endpointsCreated'] <= stamps['pairReady'] <= stamps['cleanupBegan'] <= stamps['nativeCleanupWaitReturned'] <= stamps['leaseDrainEnded']
    previous = stamps['pairReady']; first_intervals, continuation_intervals = [], []
    assert [r['observation'] for r in records[1:5]] == result['requests']
    for index, request in enumerate(result['requests']):
        assert (request['phase'], request['iteration']) == (('warmup', 0) if index == 0 else ('measured', index - 1))
        all_ids.append(request['requestID'])
        keys = ['reserveBegan', 'reserveCompleted', 'startCalled', 'firstToken', 'finalToken', 'finishedCallback', 'retirementObserved', 'resourcesReleased']
        values = [request[k] for k in keys]
        assert all(type(v) is int and v > 0 for v in values) and values == sorted(values)
        assert previous <= values[0] and values[-1] <= stamps['cleanupBegan']; previous = values[-1]
        assert request['completed'] is True and request['sequenceGuardMatched'] is True and request['finishReason'] == 'length'
        assert request['firstTokenCount'] == 1 and request['finalTokenCount'] == 128 and request['bytesInUseAfterRelease'] == 0
        assert request['tokenIDs'] == config['expectedTokenIDs'] and len(request['tokenIDs']) == 128
        first = request['firstToken'] - request['startCalled']; continuation = request['finalToken'] - request['firstToken']
        assert 0 < first == request['internalOwnerControlFirstTokenNanoseconds'] < 120_000_000_000 and continuation > 0
        if index: first_intervals.append(first); continuation_intervals.append(continuation)
        pair = [obj(output / ('evidence-rank%d' % rank) / (request['requestID'] + '.json')) for rank in (0, 1)]
        assert pair[0]['agreement'] == pair[1]['agreement']
        agreement = pair[0]['agreement']
        for key in ('artifactAggregateSHA256', 'sourceConfigurationSHA256', 'planFingerprint', 'profileFingerprint', 'stageFingerprints', 'numericalPolicySHA256', 'storageCommitmentSHA256'):
            assert agreement[key] == correctness['expectedAgreement'][key]
        assert agreement['requestID'] == request['requestID'] and agreement['membershipEpoch'] == config['membershipEpoch']
        assert agreement['rankBuildSHA256'] == [native] * 2 and agreement['rankCount'] == 2 and agreement['mtpEnabled'] is False
        assert pair[0]['execution']['agreementFingerprint'] == pair[1]['execution']['agreementFingerprint']
        assert pair[0]['execution']['tokenChainSHA256'] == pair[1]['execution']['tokenChainSHA256']
        for rank, evidence in enumerate(pair):
            x = evidence['execution']
            assert evidence['rank'] == rank and x['selectedTokenIDs'] == request['tokenIDs']
            assert x['identity']['stageIndex'] == rank and x['identity']['stageFingerprint'] == agreement['stageFingerprints'][rank]
            assert x['identity']['requestFingerprint'] == agreement['requestFingerprint']
            assert x['completedFrames'] == 143 and x['committedTokens'] == 8319 and x['bothRequestStatesRetired'] is True
            if mode == 'lookahead':
                assert agreement['prefillSchedulingPolicy'] == 'oneChunkLookahead'
                assert x['prefillSchedule'] == dict(policy='oneChunkLookahead', rank=rank, preparedAheadFrames=15 if rank == 0 else 0,
                    maximumPreparedBoundaries=1 if rank == 0 else 0, pendingConsumedAtCompletion=0, decodePrefetchCount=0)
            else:
                assert 'prefillSchedulingPolicy' not in agreement and 'prefillSchedule' not in x
    resources = []
    for rank in (0, 1):
        postflight = obj(output / ('postflight-%d.json' % rank))
        assert postflight['processes'] == [] and postflight['leaseFiles'] and all(p['bytes'] == 0 for p in postflight['leaseFiles'])
        samples = lines(output / ('resources-%d.jsonl' % rank)); assert samples
        for i, sample in enumerate(samples):
            assert sample['ordinal'] == i and type(sample['actualFreeBytes']) is int
            assert sample['startedMonotonicNS'] <= sample['completedMonotonicNS']
            page = int(re.search(r'page size of (\d+) bytes', sample['rawVMStat'])[1])
            free = int(re.search(r'Pages free:\s+(\d+)\.', sample['rawVMStat'])[1])
            assert sample['actualFreeBytes'] == page * free >= 6 * 1024**3
            assert sample['admissible'] is True and sample['acPower'] is True
            assert type(sample['pressureLevel']) is int and sample['pressureLevel'] == 1
            assert Decimal(sample['reportedSwapBytes']) == 0
        resources.append({'rank': rank, 'samples': len(samples), 'minimum_free_bytes': min(s['actualFreeBytes'] for s in samples)})
    median_ns = sorted(first_intervals)[1]
    rate = Fraction(8192 * 10**9, median_ns)
    median_continuation_rate = sorted(Fraction(127 * 10**9, n) for n in continuation_intervals)[1]
    supplied = comparison['cohorts'][mode]
    assert supplied['medianInternalFirstTokenSeconds'] == float(Fraction(median_ns, 10**9))
    assert supplied['medianEffectivePromptTokensPerSecond'] == float(rate)
    assert supplied['medianContinuationTokensPerSecond'] == float(median_continuation_rate)
    for actual, declared in zip(resources, supplied['resources']):
        assert (actual['samples'], actual['minimum_free_bytes']) == (declared['sampleCount'], declared['minimumActualFreeBytes'])
    results[mode] = {'measured_first_intervals_ns': first_intervals, 'median_first_ns': median_ns,
        'median_effective_tps_fraction': str(rate), 'median_effective_tps': float(rate),
        'resources': resources, 'both_cleanup_and_lease_ack': True, 'all_eight_stage_evidence_records_joined': True}
assert configurations[0]['promptTokenIDs'] == configurations[1]['promptTokenIDs']
assert configurations[0]['expectedTokenIDs'] == configurations[1]['expectedTokenIDs']
assert executions[0]['startedUnix'] + executions[0]['elapsedSeconds'] < executions[1]['startedUnix']
assert len(all_ids) == len(set(all_ids)) == 8
ratio = Fraction(results['serial']['median_first_ns'], results['lookahead']['median_first_ns'])
results['ratios'] = {'effective_tps_ratio': str(ratio), 'effective_tps_increase_percent': float(100 * (ratio - 1)),
    'first_token_reduction_percent': float(100 * (1 - 1 / ratio))}
assert abs(results['ratios']['first_token_reduction_percent'] - comparison['comparison']['internalFirstTokenReductionPercent']) < 1e-12
for path, digest in pins.items(): assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest
(OUTPUT / 'records/independent-wakeup-timing.json').write_text(json.dumps({'passed': True, 'results': results,
    'input_pins': pins, 'resource_samples_are_not_continuous_memory_proof': True,
    'fresh_request_full_numerical_comparison_performed': False, 'native_or_gpu_execution': False}, sort_keys=True, indent=2) + '\n')
print(json.dumps({'passed': True, 'results': results}, sort_keys=True))
