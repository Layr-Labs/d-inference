"""Join timing sidecars to control receipts; no reference logits/state comparison."""
from pathlib import Path
import base64
import hashlib
import json
import sys

BASE = Path(__file__).resolve().parent
SOURCE = BASE.parent / 'qwen9b-balanced-prefill-candidate-20260915'


def main():
    assert len(sys.argv) == 2 and sys.argv[1] in ('cut4-timing', 'cut16-timing')
    case = sys.argv[1]
    cut = 4 if case == 'cut4-timing' else 16
    sys.path.insert(0, str(BASE / 'helpers' / ('cut' + str(cut))))
    import audit_common as common
    from audit_candidate import EVIDENCE_KEYS, EXECUTION_KEYS, check_capture_budget
    from audit_state import check_entries
    from recorded_math import digest
    pins = {}

    def raw(path, cap=16*1024**2):
        value = path.read_bytes()
        assert 0 < len(value) <= cap
        pins[str(path)] = digest(value)
        return value

    def read(path, cap=16*1024**2):
        return common.parse(raw(path, cap))

    folder = SOURCE / 'cases' / case
    config_path = folder / 'configuration/controller.json'
    config = read(config_path)
    declaration = read(folder / 'case.json')
    metadata = read(SOURCE / ('metadata/cut' + str(cut) + '.json'))
    partition = read(SOURCE / 'partition-checks.json')['cuts'][str(cut)]
    lines = [common.parse(line) for line in raw(folder / 'physical-1/controller.stdout.jsonl').splitlines() if line]
    assert [line['schema'] for line in lines] == ['owner_timing_cohort_started_v1'] + ['owner_timing_request_v1']*4 + ['owner_timing_cohort_result_v1']
    started, final = lines[0], lines[-1]
    observations = [line['observation'] for line in lines[1:-1]]
    common.exact(final['requests'], observations, 'duplicated controller records')
    common.exact([item['phase'] for item in observations], ['warmup','measured','measured','measured'], 'warmup exclusion')
    common.exact([item['iteration'] for item in observations], [0,0,1,2], 'iteration order')
    assert len({x['requestID'] for x in observations}) == 4
    for line in lines:
        common.exact(line['configurationSHA256'], pins[str(config_path)], 'controller configuration binding')
    for value in (started, final):
        for key in ('cohortLabel','policyLabel','warmupCount','measuredCount'):
            if key in value:
                common.exact(value[key], config[key], 'cohort '+key)
    common.exact(started['membershipEpoch'], config['membershipEpoch'], 'controller epoch')
    common.exact(config['membershipEpoch'], declaration['membershipEpoch'], 'case epoch')
    common.exact(final['completed'], True, 'cohort completion')
    common.exact(final['nativeCleanupObserved'], [True,True], 'controller cleanup')
    common.exact(final['ownerDeviceLeaseReleasedObserved'], [True,True], 'controller release acknowledgments')
    common.exact(config['chunkSize'], 512, 'chunk')
    common.exact(config['outputCount'], 128, 'output')
    common.exact(config['stopTokenIDs'], [], 'stops')
    prompt = raw(SOURCE / 'inputs/prompt.ids.json')
    common.exact(digest(prompt), common.PROMPT_SHA, 'fixed prompt bytes')
    common.exact(common.parse(prompt), config['promptTokenIDs'], 'controller prompt IDs')
    common.token_ids(config['expectedTokenIDs'], 128)
    common.exact(metadata['planFingerprint'], common.PLAN, 'retained Plan')
    common.exact(partition['planSHA256'], common.PLAN, 'partition Plan')
    common.exact([load['stagePlanSHA256'] for load in metadata['loads']], common.STAGES, 'stage Plan identities')
    common.exact([load['constructionConfigurationSHA256'] for load in metadata['loads']], common.CONSTRUCTIONS, 'construction identities')
    for rank in range(2):
        owner = read(folder / 'configuration' / ('owner-rank'+str(rank)+'.json'))
        ready = common.parse(base64.b64decode(owner['readyTemplateBase64'],validate=True))['ready']
        common.exact(owner['stageCut'], cut, 'owner cut')
        common.exact(ready['executionPlanSHA256'], common.PLAN, 'ready Plan')
        common.exact(ready['rank'], rank, 'ready rank')
        common.exact(ready['identity']['artifactSHA256'], common.ARTIFACT, 'artifact')
        common.exact(ready['identity']['configurationSHA256'], common.CONFIG, 'source configuration')
        common.exact([peer['buildSHA256'] for peer in ready['identity']['peers']], [declaration['nativeSHA256']]*2, 'worker build declarations')
        common.exact(owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'], 'one_chunk_lookahead_v1', 'configured policy')
    collection = read(BASE / 'collection-1/collection.json')
    records = [x for x in collection['records'] if x['case'] == case]
    assert [x['rank'] for x in records] == [0,1]
    names = sorted(x['requestID']+'.json' for x in observations)
    for record in records:
        common.exact(record['expectedNames'], names, 'exact expected UUIDs')
        common.exact(record['observedBefore'], names, 'directory before')
        common.exact(record['observedAfter'], names, 'directory after')
    result_rows = []
    for observation in observations:
        for key,value in dict(completed=True,sequenceGuardMatched=True,firstTokenCount=1,finalTokenCount=128,
                              finishReason='length',bytesInUseAfterRelease=0).items():
            common.exact(observation[key],value,'controller '+key)
        common.exact(observation['tokenIDs'], config['expectedTokenIDs'], '128 controller output guard')
        context = common.request_context(prompt, observation['requestID'])
        expected = dict(schema='qwen_stage_generation_agreement_v1',rankCount=2,
            membershipEpoch=config['membershipEpoch'],requestID=context['request_id'],
            requestFingerprint=context['fingerprint'],profileFingerprint=common.profile()['fingerprint'],
            sourceConfigurationSHA256=common.CONFIG,artifactAggregateSHA256=common.ARTIFACT,
            storageCommitmentSHA256=partition['storageCommitmentSHA256'],planFingerprint=common.PLAN,
            stageFingerprints=common.STAGES,rankBuildSHA256=[declaration['nativeSHA256']]*2,
            numericalPolicySHA256=common.ARITHMETIC,mtpEnabled=False,prefillSchedulingPolicy='oneChunkLookahead')
        agreement_hash = common.agreement(expected,context)
        chains, sidecar_rows = [], []
        for rank in range(2):
            path = BASE / 'collection-1' / case / ('rank'+str(rank)) / (context['request_id']+'.json')
            evidence = read(path)
            record = next(x for x in records[rank]['files'] if x['name'] == path.name)
            common.exact(pins[str(path)],record['sha256'],'collected sidecar hash')
            common.fields(evidence,EVIDENCE_KEYS+(' finalLogits' if rank else ''),'sidecar')
            for key,value in dict(schema='qwen_stage_generation_final_diagnostic_v1',agreement=expected,
                requestFingerprint=context['fingerprint'],profileFingerprint=common.profile()['fingerprint'],rank=rank,
                sourceLayerStart=common.RANGES[rank][0],sourceLayerEnd=common.RANGES[rank][1],
                finalFrame=common.selected_frame(127),actualAllocatorBoundsUsed=True,correctnessOnly=True,
                throughputMeasurementValid=False,stateBytesIncluded=False,intermediateLogitRowsCompared=False,
                independentNumericalComparisonPerformed=False,physicalTransferQualified=False).items():
                common.exact(evidence[key],value,'sidecar '+key)
            execution = common.fields(evidence['execution'],EXECUTION_KEYS,'execution')
            identity = dict(stageIndex=rank,requestFingerprint=context['fingerprint'],
                artifactAggregateSHA256=common.ARTIFACT,storageCommitmentSHA256=partition['storageCommitmentSHA256'],
                bf16ConversionEnabled=True,sourceConfigurationSHA256=common.CONFIG,
                constructionConfigurationSHA256=common.CONSTRUCTIONS[rank],planFingerprint=common.PLAN,
                stageFingerprint=common.STAGES[rank],activationDType='bfloat16')
            schedule = dict(policy='oneChunkLookahead',rank=rank,preparedAheadFrames=15 if rank==0 else 0,
                maximumPreparedBoundaries=1 if rank==0 else 0,pendingConsumedAtCompletion=0,decodePrefetchCount=0)
            for key,value in dict(schema='qwen_stage_generation_result_v1',agreementFingerprint=agreement_hash,
                membershipEpoch=config['membershipEpoch'],identity=identity,selectedTokenIDs=observation['tokenIDs'],
                completedFrames=143,committedTokens=8319,finishReason='length',bothRequestStatesRetired=True,
                modelRemainsResident=True,mtpEnabled=False,physicalTransferQualified=False,
                independentNumericalComparisonPerformed=False,externalTTFTMeasured=False,prefillSchedule=schedule).items():
                common.exact(execution[key],value,'execution '+key)
            chains.append(common.sha(execution['tokenChainSHA256']))
            size, state_hash = check_entries(evidence['stateEntries'],*common.RANGES[rank])
            common.exact(size,evidence['logicalStateBytes'],'state logical bytes')
            common.exact(state_hash,evidence['stageStateSHA256'],'reported state fingerprint')
            check_capture_budget(evidence['captureBudget'],rank)
            sidecar_rows.append(dict(rank=rank,sha256=pins[str(path)],prefillSchedule=schedule,
                completedFrames=143,committedTokens=8319,stateEntryCount=len(evidence['stateEntries']),
                reportedStateMetadataInternallyConsistent=True))
        common.exact(chains[0],chains[1],'both ranks token chain')
        result_rows.append(dict(requestID=context['request_id'],phase=observation['phase'],iteration=observation['iteration'],
            requestFingerprint=context['fingerprint'],agreementFingerprint=agreement_hash,expectedAgreement=expected,
            selected128IDsMatchedControllerAndConfiguredGuard=True,selectedTokenIDsSHA256=common.token_hash(observation['tokenIDs']),
            tokenChainSHA256=chains[0],tokenChainIndependentlyReconstructed=False,sidecars=sidecar_rows))
    for path,pin in pins.items():
        assert digest(Path(path).read_bytes()) == pin
    result = dict(schema='balanced_timing_sidecar_identity_join_v1',case=case,cut=cut,status='passed',
        membershipEpoch=config['membershipEpoch'],requestCount=4,warmupCount=1,measuredCount=3,
        planFingerprint=common.PLAN,nativeBuildSHA256=declaration['nativeSHA256'],requests=result_rows,inputPins=pins,
        allExpectedSidecarsPresent=True,extraSidecarsObserved=False,nativeReportedScheduleValidated=True,
        policyEngagementIndependentlyAttested=False,nativeBinaryRehashedDuringCollection=False,
        bothRanksCurrentlyProcessAbsent=all(not x['active'] for x in records),
        bothCanonicalJournalsCurrentlyEmpty=all(x['journalBytes']==0 for x in records),
        fullNumericalComparisonPerformed=False,finalLogitBytesCompared=False,stateComparedWithReference=False,
        newTimingMeasurementPerformed=False,externalTTFTMeasured=False,frozenPublicReportChanged=False,
        scope='Controller/config/sidecar identity and reported schedule/frame join; no new numerical or physical policy attestation.')
    with (BASE / ('join-'+case+'.json')).open('x') as stream:
        json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps({k:result[k] for k in ('case','status','requestCount','allExpectedSidecarsPresent','bothRanksCurrentlyProcessAbsent','bothCanonicalJournalsCurrentlyEmpty')}))


if __name__ == '__main__':
    main()
