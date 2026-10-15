"""Validate completed controller clocks and cleanup before deriving timing rates."""
import hashlib
import math
import statistics
import uuid


def require(value, message):
    if not value:
        raise ValueError(message)


def token_hash(values):
    return hashlib.sha256(','.join(map(str, values)).encode()).hexdigest()


def validate_cohort(config, config_sha, lines, execution):
    require(type(lines) is list and len(lines) == 4, 'Complete 1+1 controller stream required')
    require([x.get('schema') for x in lines] == ['owner_timing_cohort_started_v1'] +
            ['owner_timing_request_v1'] * 2 + ['owner_timing_cohort_result_v1'], 'Controller record order differs')
    started, final = lines[0], lines[-1]
    observations = [x['observation'] for x in lines[1:-1]]
    require(final['requests'] == observations, 'Final request records differ')
    require(all(x['configurationSHA256'] == config_sha for x in lines), 'Controller configuration pin differs')
    require(started['membershipEpoch'] == config['membershipEpoch'], 'Epoch differs')
    require((config['warmupCount'], config['measuredCount'], len(config['promptTokenIDs']),
             config['chunkSize'], config['outputCount'], config['stopTokenIDs']) == (1, 1, 8192, 512, 128, []),
            'Matched input geometry differs')
    for item in (started, final):
        require(item['cohortLabel'] == config['cohortLabel'] and item['policyLabel'] == config['policyLabel'], 'Cohort differs')
        require(item['promptTokenIDsSHA256'] == token_hash(config['promptTokenIDs']) and
                item['expectedTokenIDsSHA256'] == token_hash(config['expectedTokenIDs']), 'Token guard hash differs')
    require(final['completed'] is True, 'Incomplete controller')
    for key in ('nativeCleanupObserved', 'ownerDeviceLeaseReleasedObserved'):
        require(type(final[key]) is list and len(final[key]) == 2 and all(x is True for x in final[key]),
                'Incomplete native/owner cleanup')
    require(final['clock'] == 'DispatchTime.uptimeNanoseconds.same_controller_process', 'Clock scope differs')
    require(execution.get('runCompletedAndAliasRestored') is True and execution.get('pinsUnchanged') is True and
            execution.get('controllerExitCode') == 0 and execution.get('nativeProcessesAbsent') is True and
            execution.get('journalsEmpty') is True, 'Incomplete parent/postflight')
    child = execution.get('localController', {})
    require(child.get('reaped') is True and child.get('groupAbsent') is True, 'Owned controller not reaped/fenced')
    lease = execution.get('leaseFinal', [])
    monitors = execution.get('monitors', [])
    require(execution.get('leaseExitCode') == 0 and len(lease) == 1 and lease[0].get('restored') is True,
            'Alias restoration not confirmed')
    require(len(monitors) == 2 and all(x.get('exitCode') == 0 and x.get('errors') == [] for x in monitors),
            'Resource monitors did not finish cleanly')
    identifiers = [x['requestID'] for x in observations]
    require(len(set(identifiers)) == 2 and all(str(uuid.UUID(x)) == x for x in identifiers), 'Fresh canonical UUIDs required')
    require([x['phase'] for x in observations] == ['warmup', 'measured'] and
            [x['iteration'] for x in observations] == [0, 0], 'Warmup/iteration order differs')
    rows = []
    for observation in observations:
        require(observation.get('completed') is True and observation.get('sequenceGuardMatched') is True and
                observation.get('failure') is None and observation['tokenIDs'] == config['expectedTokenIDs'] and
                len(observation['tokenIDs']) == 128 and observation['finishReason'] == 'length' and
                observation['firstTokenCount'] == 1 and observation['finalTokenCount'] == 128 and
                observation['bytesInUseAfterRelease'] == 0, 'Incomplete request/output/retirement')
        names = ('reserveBegan', 'reserveCompleted', 'startCalled', 'firstToken', 'finalToken',
                 'finishedCallback', 'retirementObserved', 'resourcesReleased')
        stamps = [observation[x] for x in names]
        require(all(type(x) is int and 0 <= x <= 2**64-1 for x in stamps) and stamps == sorted(stamps), 'Invalid ordered clocks')
        first = observation['firstToken'] - observation['startCalled']
        decode = observation['finalToken'] - observation['firstToken']
        require(first > 0 and decode > 0 and observation['internalOwnerControlFirstTokenNanoseconds'] == first,
                'First-token or continuation clock differs')
        rows.append(dict(requestID=observation['requestID'], phase=observation['phase'], iteration=observation['iteration'],
            internalFirstTokenNanoseconds=first, continuationNanoseconds=decode,
            prefillTokensPerSecond=8192 * 1e9 / first, continuationTokensPerSecond=127 * 1e9 / decode))
    measured = rows[1:]
    values = sorted(x['internalFirstTokenNanoseconds'] for x in measured)
    summary = final['summary']
    require(summary['complete'] is True and summary['completeMeasuredCount'] == 1 and
            summary['warmupsExcluded'] is True and summary['measuredInternalOwnerControlFirstTokenNanoseconds'] == values and
            summary['medianInternalOwnerControlFirstTokenNanoseconds'] == values[0], 'Controller summary differs from raw clocks')
    result = dict(requests=rows, warmupCount=1, measuredCount=1, warmupExcluded=True,
        medianInternalFirstTokenSeconds=statistics.median(x['internalFirstTokenNanoseconds'] for x in measured) / 1e9,
        medianPrefillTokensPerSecond=statistics.median(x['prefillTokensPerSecond'] for x in measured),
        medianContinuationTokensPerSecond=statistics.median(x['continuationTokensPerSecond'] for x in measured),
        prefillNumerator=8192, continuationNumerator=127, wholeControllerElapsedUsedAsThroughput=False,
        diagnosticEOFCompletenessProven=False, externalTTFTMeasured=False, encryptedRDMAQualified=False,
        fullNumericalComparisonPerformed=False, providerCapacityUpdated=False)
    require(all(math.isfinite(result[x]) and result[x] > 0 for x in
            ('medianInternalFirstTokenSeconds', 'medianPrefillTokensPerSecond', 'medianContinuationTokensPerSecond')),
            'Invalid derived rates')
    return result
