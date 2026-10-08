"""Prospective P32/C16/O2 value checks; no model execution or physical attestation."""
import uuid
from probe_values import (ARTIFACT, CONFIG, PLAN, STAGES, CONSTRUCTIONS, VOCAB,
    fields, exact, integer, sha, canonical_uuid, token_hash, profile, agreement,
    digest, canonical, require)

EXECUTION_KEYS = ('schema agreementFingerprint membershipEpoch identity selectedTokenIDs tokenChainSHA256 '
    'completedFrames committedTokens finishReason bothRequestStatesRetired modelRemainsResident mtpEnabled '
    'physicalTransferQualified independentNumericalComparisonPerformed externalTTFTMeasured')
PROBE_KEYS = ('schema rank probeReadinessFingerprint execution targetSecondToken '
    'proposalWasConsumedAsTargetInput speculativeAcceptanceImplemented')
ASSISTANT_KEYS = ('proposal assistantInputsBeforeProposal assistantInputsAfterProposal '
    'assistantRequestReleased proposalMatchesTarget')


def context(request):
    canonical_uuid(request['requestID'])
    exact(request['modelID'], 'registered_qwen35_9b', 'request model')
    exact(request['profileID'], profile()['identifier'], 'request profile')
    exact(request['chunkSize'], 16, 'request chunk')
    exact(request['outputCount'], 2, 'request outputs')
    exact(request['stopTokenIDs'], [], 'request stops')
    exact(request['stageCut'], 4, 'request cut')
    exact(request['prefillSchedule'], 'serial_v1', 'request policy')
    exact(request['speculativeAcceptanceImplemented'], False, 'request speculative acceptance')
    tokens = request['promptTokenIDs']
    require(type(tokens) is list and len(tokens) == 32, 'Prompt must have32 IDs')
    for token in tokens:
        integer(token, 0, VOCAB - 1)
    pin = token_hash(tokens)
    fingerprint = digest('\n'.join(['qwen-stage-generation-request-v1', profile()['fingerprint'],
        request['requestID'], 'prompt=' + pin, 'chunk=16', 'output=2', 'stop=']).encode())
    return dict(request_id=request['requestID'], fingerprint=fingerprint, prompt_tokens_sha=pin)


def native_uuid(value):
    # Foundation UUID's Encodable representation may use uppercase hex. Compare
    # its typed identity while refusing alternate UUID spellings/braces/URNs.
    require(type(value) is str and len(value) == 36, 'Wrong native UUID representation')
    parsed = str(uuid.UUID(value))
    require(value in (parsed, parsed.upper()), 'Noncanonical native UUID spelling')
    return parsed


def compare(request, expected_agreement, candidates, controller_records, controller_sha):
    ctx = context(request)
    expected_hash = agreement(expected_agreement, ctx)
    probe_hash = digest(canonical(['registered-qwen35-9b-single-unaccepted-proposal-v1', expected_hash,
        'head-rank1', 'replicated-input-embedding', 'depth1', 'ordinary-target-seed-decode']))
    require(type(candidates) is list and len(candidates) == 2, 'Exactly two ranked sidecars required')
    selected = None
    for rank, value in enumerate(candidates):
        fields(value, PROBE_KEYS + (' ' + ASSISTANT_KEYS if rank == 1 else ''), 'probe sidecar')
        for key, expected in dict(schema='qwen_stage_single_unaccepted_mtp_proposal_v1', rank=rank,
            probeReadinessFingerprint=probe_hash, proposalWasConsumedAsTargetInput=False,
            speculativeAcceptanceImplemented=False).items():
            exact(value[key], expected, 'probe.' + key)
        execution = fields(value['execution'], EXECUTION_KEYS, 'execution')
        tokens = execution['selectedTokenIDs']
        require(type(tokens) is list and len(tokens) == 2, 'Two target IDs are required')
        for token in tokens:
            integer(token, 0, VOCAB - 1)
        if selected is None:
            selected = tokens
        exact(tokens, selected, 'rank target IDs')
        identity = dict(stageIndex=rank, requestFingerprint=ctx['fingerprint'], artifactAggregateSHA256=ARTIFACT,
            storageCommitmentSHA256=expected_agreement['storageCommitmentSHA256'], bf16ConversionEnabled=True,
            sourceConfigurationSHA256=CONFIG, constructionConfigurationSHA256=CONSTRUCTIONS[rank],
            planFingerprint=PLAN, stageFingerprint=STAGES[rank], activationDType='bfloat16')
        for key, expected in dict(schema='qwen_stage_generation_result_v1', agreementFingerprint=expected_hash,
            membershipEpoch=expected_agreement['membershipEpoch'], identity=identity,
            completedFrames=3, committedTokens=33, finishReason='length', bothRequestStatesRetired=True,
            modelRemainsResident=True, mtpEnabled=False, physicalTransferQualified=False,
            independentNumericalComparisonPerformed=False, externalTTFTMeasured=False).items():
            exact(execution[key], expected, 'execution.' + key)
        sha(execution['tokenChainSHA256'])
        exact(value['targetSecondToken'], selected[1], 'target second token')
    exact(candidates[0]['execution']['tokenChainSHA256'], candidates[1]['execution']['tokenChainSHA256'], 'final chain')
    final = candidates[1]
    proposal = fields(final['proposal'], 'requestID roundID agreementFingerprint committedTargetInputs seedTokenID '
        'previousTokenChainSHA256 proposedTokenID draftDepth accepted', 'proposal')
    exact(native_uuid(proposal['requestID']), request['requestID'], 'proposal request UUID')
    require(native_uuid(proposal['roundID']) != str(uuid.UUID(int=0)), 'Proposal round must be nonzero')
    for key, expected in dict(agreementFingerprint=expected_hash, committedTargetInputs=32,
        seedTokenID=selected[0], draftDepth=1, accepted=False).items():
        exact(proposal[key], expected, 'proposal.' + key)
    draft = integer(proposal['proposedTokenID'], 0, VOCAB - 1)
    previous = sha(proposal['previousTokenChainSHA256'])
    initial = digest(('qwen-generation-history-v1|' + expected_hash + '|' + ctx['prompt_tokens_sha']).encode())
    require(previous != initial and previous != candidates[0]['execution']['tokenChainSHA256'], 'Token chain did not advance across both target selections')
    for key, expected in dict(assistantInputsBeforeProposal=31, assistantInputsAfterProposal=32,
        assistantRequestReleased=True, proposalMatchesTarget=(draft == selected[1])).items():
        exact(final[key], expected, 'assistant.' + key)
    check_controller(controller_records, controller_sha, request, expected_agreement, selected)
    return dict(schema='private_registered_mtp_probe_comparison_v1', status='passed',
        requestID=request['requestID'], membershipEpoch=expected_agreement['membershipEpoch'],
        requestFingerprint=ctx['fingerprint'], agreementFingerprint=expected_hash, probeReadinessFingerprint=probe_hash,
        targetTokenIDs=selected, unacceptedProposalID=draft, proposalMatchesTarget=(draft == selected[1]),
        assistantInputCounts=[31, 32], finalCompletedFrames=3, finalCommittedInputs=33,
        targetTokensComparedAcrossRanks=2, tokenChainCrossRankEqualityChecked=True,
        tokenChainIndependentlyReconstructed=False, sourceStorageIdentityComparedAsOpaque=True,
        independentTargetNumericalComparisonPerformed=False, speculativeAcceptanceImplemented=False,
        controllerCleanupClaimsChecked=True, physicalCleanupIndependentlyAudited=False,
        runtimeResourceSamplesAudited=False, actualInstalledBinaryIndependentlyAttested=False,
        performanceQualification=False, externalTTFTMeasured=False)


def check_controller(records, config_sha, request, expected_agreement, selected):
    require(type(records) is list and len(records) == 2, 'Expected exactly started and terminal controller records')
    started = fields(records[0], 'schema configurationSHA256 cpuQualification membershipEpoch requestID promptCount '
        'outputCount performanceQualification numericalQualification', 'controller started')
    for key, expected in dict(schema='owner_qualification_started_v1', configurationSHA256=sha(config_sha),
        cpuQualification=False, membershipEpoch=expected_agreement['membershipEpoch'], requestID=request['requestID'],
        promptCount=32, outputCount=2, performanceQualification=False, numericalQualification=False).items():
        exact(started[key], expected, 'controller started.' + key)
    result = fields(records[1], 'schema configurationSHA256 cpuQualification completed tokenIDs performanceQualification '
        'numericalQualification nativeCleanupObserved ownerDeviceLeaseReleasedObserved endpointDiagnosticsBase64 '
        'journalRelease elapsedControllerNanoseconds finishReason', 'controller result')
    for key, expected in dict(schema='owner_qualification_result_v1', configurationSHA256=config_sha,
        cpuQualification=False, completed=True, tokenIDs=selected, finishReason='length', performanceQualification=False,
        numericalQualification=False, nativeCleanupObserved=[True, True], ownerDeviceLeaseReleasedObserved=[True, True]).items():
        exact(result[key], expected, 'controller result.' + key)
    integer(result['elapsedControllerNanoseconds'], 1, 305_000_000_000)
    require(type(result['endpointDiagnosticsBase64']) is list and len(result['endpointDiagnosticsBase64']) == 2
            and all(type(x) is str for x in result['endpointDiagnosticsBase64']), 'Controller diagnostics shape differs')
    require(type(result['journalRelease']) is str, 'Missing controller cleanup scope label')
