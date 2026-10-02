"""Join pinned timing, cleanup, raw resources and native sidecar declarations."""
from pathlib import Path
import argparse
import hashlib
import json
import sys
from timing_results import validate_cohort
from package_checks import verify_package

BASE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--case', choices=('serial', 'lookahead'), required=True)
    args = parser.parse_args()
    verify_package()
    case = BASE / args.case
    sys.path.insert(0, str(BASE / 'helpers' / args.case))
    sys.path.insert(0, str(case))
    import audit_common as common
    from audit_scope import pinned_scope
    from audit_candidate import EVIDENCE_KEYS, EXECUTION_KEYS, check_capture_budget
    from audit_state import check_entries
    from reference_resources import sample_local, validate_local
    from snapshot import snapshot
    saved = []
    def raw(path, cap=16*1024**2):
        item = snapshot(path, cap)
        saved.append((path, cap, {k:v for k,v in item.items() if k != 'raw'}))
        return item['raw']
    def read(path, cap=16*1024**2): return common.parse(raw(path, cap))
    config_raw = raw(case / 'configuration/controller.json')
    config = common.parse(config_raw)
    declaration = read(case / 'case.json')
    metadata = read(case / 'provenance/recording-metadata.json')
    identity = read(case / 'provenance/expected-identity.json')
    request = read(case / 'inputs/request.json')
    scope = pinned_scope(request, metadata)
    common.exact((scope.model_id, scope.cut, scope.prompt, scope.chunk, scope.output),
                 ('registered_qwen38_27b', 16, 8192, 512, 128), 'Registered timing scope')
    prompt = raw(case / 'inputs/prompt.ids.json')
    common.exact(common.parse(prompt), config['promptTokenIDs'], 'Exact prompt IDs')
    common.exact(hashlib.sha256(prompt).hexdigest(), request['promptFileSHA256'], 'Prompt source bytes')
    shared = read(Path(declaration['sharedInputs']['path']))
    common.exact(config['expectedTokenIDs'], shared['expectedTokenIDs'], 'Validated reference output guard')
    common.exact(config['membershipEpoch'], declaration['membershipEpoch'], 'Declared epoch')
    common.exact(declaration['nativeSHA256'], metadata['nativeBinarySHA256'], 'Declared native build')
    execution = read(case / 'physical-1/execution.json')
    lines = [common.parse(x) for x in raw(case / 'physical-1/controller.stdout.jsonl').splitlines() if x]
    metrics = validate_cohort(config, hashlib.sha256(config_raw).hexdigest(), lines, execution)
    observations = [x['observation'] for x in lines[1:-1]]
    resource_rows = []
    for rank in (0, 1):
        samples = [common.parse(x) for x in raw(case / ('physical-1/resources-' + str(rank) + '.jsonl')).splitlines() if x]
        common.exact([x['ordinal'] for x in samples], list(range(len(samples))), 'Resource ordinal sequence')
        common.integer(len(samples), 1, 1400)
        for sample in samples:
            common.exact(sample['admissible'], True, 'Resource monitor acceptance')
            validate_local(sample)
            # Reuse the original parser on the retained OS text; no subprocess.
            values = iter([sample['rawMemory'], sample['rawVMStat'], sample['rawPower']])
            replay = sample_local(read=lambda _:next(values))
            for key in ('actualFreeBytes', 'pressureLevel', 'reportedSwapBytes', 'acPower'):
                common.exact(replay[key], sample[key], 'Raw resource ' + key)
        resource_rows.append(dict(rank=rank, sampleCount=len(samples), minimumActualFreeBytes=min(x['actualFreeBytes'] for x in samples)))
    collection = read(case / 'collection-1/collection.json')
    records = collection['records']
    common.exact([x['rank'] for x in records], [0,1], 'Collected ranks')
    names = sorted(x['requestID'] + '.json' for x in observations)
    for record in records:
        for key in ('expectedNames', 'observedBefore', 'observedAfter'):
            common.exact(record[key], names, 'Four exact sidecars ' + key)
        common.exact(record['active'], [], 'Current native process absence')
        common.exact(record['journalBytes'], 0, 'Current empty canonical journal')
    joins = []
    for observation in observations:
        context = common.request_context(prompt, observation['requestID'], scope)
        expected = dict(schema='qwen_stage_generation_agreement_v1', rankCount=2,
            membershipEpoch=config['membershipEpoch'], requestID=context['request_id'], requestFingerprint=context['fingerprint'],
            profileFingerprint=common.profile(scope)['fingerprint'], sourceConfigurationSHA256=scope.model['configuration'],
            artifactAggregateSHA256=scope.model['artifact'], storageCommitmentSHA256=identity['storageCommitmentSHA256'],
            planFingerprint=scope.plan['fingerprint'], stageFingerprints=scope.plan['stages'],
            rankBuildSHA256=[declaration['nativeSHA256']]*2, numericalPolicySHA256=identity['arithmeticSHA256'], mtpEnabled=False)
        if args.case == 'lookahead': expected['prefillSchedulingPolicy'] = 'oneChunkLookahead'
        agreement = common.agreement(expected, context)
        chains, ranked = [], []
        for rank in (0,1):
            path = case / 'collection-1' / ('rank'+str(rank)) / (context['request_id']+'.json')
            data = raw(path); evidence = common.parse(data)
            item = next(x for x in records[rank]['files'] if x['name']==path.name)
            common.exact(hashlib.sha256(data).hexdigest(), item['sha256'], 'Collected sidecar bytes')
            common.fields(evidence, EVIDENCE_KEYS + (' finalLogits' if rank else ''), 'Sidecar')
            for key,value in dict(schema='qwen_stage_generation_final_diagnostic_v1', agreement=expected,
                requestFingerprint=context['fingerprint'], profileFingerprint=common.profile(scope)['fingerprint'], rank=rank,
                sourceLayerStart=scope.ranges[rank][0], sourceLayerEnd=scope.ranges[rank][1],
                finalFrame=common.selected_frame(127,scope), actualAllocatorBoundsUsed=True, correctnessOnly=True,
                throughputMeasurementValid=False, stateBytesIncluded=False, intermediateLogitRowsCompared=False,
                independentNumericalComparisonPerformed=False, physicalTransferQualified=False).items():
                common.exact(evidence[key], value, 'Sidecar ' + key)
            native = common.fields(evidence['execution'], EXECUTION_KEYS, 'Native execution')
            bound = dict(stageIndex=rank,requestFingerprint=context['fingerprint'],artifactAggregateSHA256=scope.model['artifact'],
                storageCommitmentSHA256=expected['storageCommitmentSHA256'],bf16ConversionEnabled=True,
                sourceConfigurationSHA256=scope.model['configuration'],constructionConfigurationSHA256=scope.plan['constructions'][rank],
                planFingerprint=scope.plan['fingerprint'],stageFingerprint=scope.plan['stages'][rank],activationDType='bfloat16')
            for key,value in dict(schema='qwen_stage_generation_result_v1',agreementFingerprint=agreement,
                membershipEpoch=config['membershipEpoch'],identity=bound,selectedTokenIDs=observation['tokenIDs'],
                completedFrames=143,committedTokens=8319,finishReason='length',bothRequestStatesRetired=True,
                modelRemainsResident=True,mtpEnabled=False,physicalTransferQualified=False,
                independentNumericalComparisonPerformed=False,externalTTFTMeasured=False).items():
                common.exact(native[key],value,'Native execution '+key)
            if args.case == 'lookahead':
                common.exact(native['prefillSchedule'],dict(policy='oneChunkLookahead',rank=rank,
                    preparedAheadFrames=15 if rank==0 else 0,maximumPreparedBoundaries=1 if rank==0 else 0,
                    pendingConsumedAtCompletion=0,decodePrefetchCount=0),'Reported lookahead schedule')
            size,state_hash=check_entries(evidence['stateEntries'],*scope.ranges[rank],scope=scope)
            common.exact(size,evidence['logicalStateBytes'],'State byte count')
            common.exact(state_hash,evidence['stageStateSHA256'],'State fingerprint')
            check_capture_budget(evidence['captureBudget'],rank,scope)
            common.integer(evidence['resourceObservationCount'],1)
            common.integer(evidence['minimumObservedActualFreeBytes'],6*1024**3)
            common.integer(evidence['minimumObservedAllocatorLimitBytes'],1)
            chains.append(common.sha(native['tokenChainSHA256']))
            ranked.append(dict(rank=rank,sidecarSHA256=item['sha256'],stateEntryCount=len(evidence['stateEntries']),
                nativeReportedSchedule=native.get('prefillSchedule'),stateComparedWithReference=False))
        common.exact(chains[0],chains[1],'Both-rank token chain')
        joins.append(dict(requestID=context['request_id'],agreementFingerprint=agreement,tokenChainSHA256=chains[0],sidecars=ranked))
    for path,cap,expected in saved:
        current=snapshot(path,cap,keep=False)
        common.exact({k:v for k,v in current.items() if k!='raw'},expected,'Input changed during join')
    result=dict(schema='private_qwen27b_matched_timing_result_v1',status='passed',case=args.case,
        metrics=metrics,requestJoins=joins,resources=resource_rows,allFourRequestsAndCleanupValidated=True,
        inputPins=[dict(path=str(p),**v) for p,_,v in saved],
        nativeReportedScheduleChecked=True,policyEngagementIndependentlyAttested=False,
        finalLogitBytesCompared=False,stateComparedWithReference=False,fullNumericalComparisonPerformed=False,
        externalTTFTMeasured=False,encryptedRDMAQualified=False,diagnosticEOFCompletenessProven=False)
    output=case/'timing-result-1.json'
    with output.open('x') as stream:json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps(dict(case=args.case,status='passed',outputSHA256=hashlib.sha256(output.read_bytes()).hexdigest(),
        medianInternalFirstTokenSeconds=metrics['medianInternalFirstTokenSeconds'],
        medianPrefillTokensPerSecond=metrics['medianPrefillTokensPerSecond'],
        medianContinuationTokensPerSecond=metrics['medianContinuationTokensPerSecond'])))


if __name__ == '__main__':main()
