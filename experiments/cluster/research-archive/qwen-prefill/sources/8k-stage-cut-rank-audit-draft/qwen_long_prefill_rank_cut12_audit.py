"""Bounded CPU audit for two v4 rank reports against the frozen 8K reference.

Only the reference exports a complete numerical logit row. Candidate state and
logit hashes are compared, never presented as independently captured bytes.
"""
import copy
import json
from pathlib import Path
import sys

import cut12_rank_dependencies as dependencies
import cut12_rank_trace as rank_trace
import cut12_rank_wire as rank_wire

MAX_STDOUT = 16 * 1024**2
CORE_FILES = ['qwen_long_prefill_rank_cut12_audit.py','cut12_rank_dependencies.py','cut12_rank_trace.py','cut12_rank_wire.py']
MEMORY_PHASES = ['before_stage_load','stage_loaded_no_request_state',
    'stage_request_retired_weights_resident','stage_model_released_cache_cleared']


def parse_rows(data):
    a = dependencies.context()[0]
    a.require(type(data) is bytes and 0 < len(data) <= MAX_STDOUT, 'Rank stdout exceeds bounds')
    lines = data.splitlines()
    a.require(len(lines) == 2 and all(lines), 'Exactly ready and completed report JSONL required')
    rows = []
    for line in lines:
        a.check_depth(line)
        value = a.context()['base'].parse_json(line.decode('utf8'))
        a.require(type(value) is dict, 'Rank record must be an object')
        rows.append(value)
    return rows


def memory(a, rows):
    a.require(type(rows) is list and len(rows) == 4, 'Four allocator observations required')
    peak = 0
    for row, phase in zip(rows, MEMORY_PHASES):
        a.require(type(row) is dict and set(row) == {'phase','activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart'},
            'Allocator observation schema differs')
        a.exact(row['phase'], phase, 'allocator phase')
        active = a.integer(row['activeMLXBytes']); a.integer(row['cachedMLXBytes'])
        current = a.integer(row['peakMLXBytesSinceProcessStart'])
        a.require(current >= active and current >= peak, 'Allocator peak is internally inconsistent')
        peak = current
    a.require(rows[-1]['cachedMLXBytes'] == 0, 'Native cache-clear assertion differs')
    return copy.deepcopy(rows)


def check_rank_pair(rank_rows, baseline_rows, prompt_data, expected_prompt_sha256, epoch, policy):
    """Pure-record API for fabricated tests; production validate() also pins origin files."""
    a, storage, final, pair_wire = dependencies.context()
    dependencies.pair_oracle().check_pair(a, baseline_rows, prompt_data, expected_prompt_sha256)
    reference = baseline_rows[0]['reference']
    baseline = a.check_reference(reference, prompt_data, expected_prompt_sha256)
    prompt = a.prompt_tokens(prompt_data, expected_prompt_sha256)
    recorded, simple, history = rank_wire.request(a, prompt, epoch)
    a.require(recorded['request']['requestID'].lower() != reference['execution']['request']['request']['requestID'].lower(),
        'Fresh rank request must differ from the reference request')
    summary = dict(baseline, requestFingerprint=simple, recordedRequestFingerprint=history)
    a.require(type(rank_rows) is list and len(rank_rows) == 2, 'Two ordered rank streams required')
    for rows in rank_rows:
        a.require(type(rows) is list and len(rows) == 2 and all(type(row) is dict for row in rows),
            'Each rank requires ready and report objects')
    reports = [rows[1] for rows in rank_rows]
    loads = [r.get('sourceLoad') for r in reports]
    inventory, _ = storage.check_storage(a, loads, baseline['source'])
    identities = [storage.identity(a, rank, loads[rank], summary) for rank in range(2)]
    descriptor = rank_wire.agreement(a, epoch, policy, recorded, summary, loads)
    agreement_fp = rank_wire.fingerprint(a, 'qwen-profiled-prefill-start-agreement-v1', a.canonical(descriptor))
    executions = []
    for rank, (ready, report) in enumerate(rank_rows):
        common = dict(schemaVersion=1, epoch=epoch, rank=rank, worldSize=2, transport='loopback-test', backend='ring',
            flow=rank_wire.FLOW, envelopeVersion=4, agreementFingerprint=agreement_fp, agreement=descriptor,
            promptFileSHA256=expected_prompt_sha256)
        a.exact(ready, dict(common, kind='qwen_long_prefill_rank_ready', modelsReadyAgreementValidated=True,
            freshRequestStateCreated=False), 'rank ready '+str(rank))
        wanted = dict(common, kind='qwen_long_prefill_rank_report', completed=True, correctnessOnly=True,
            throughputMeasurementValid=False, modelForwardCompared=False, physicalTransferQualified=False,
            sourceLoad=loads[rank], request=recorded, arithmeticEnvironment=a.context()['environment'],
            arithmeticEnvironmentSHA256=baseline['arithmeticEnvironmentSHA256'], resourceAdmission=a.context()['resource'],
            execution=report.get('execution'), allRequestStateRetired=True, modelReleased=True, memory=report.get('memory'))
        a.require(set(report) == set(wanted), 'Rank terminal schema differs')
        for key in wanted:
            if key not in ('sourceLoad','execution','memory'):
                a.exact(report[key], wanted[key], 'rank report '+str(rank)+'.'+key)
        memory(a, report['memory'])
        x = report['execution']; a.require(type(x) is dict, 'Missing rank execution')
        executions.append(x)
        expected = dict(kind='qwen_long_prefill_rank_request',schemaVersion=1,correctnessOnly=True,
            throughputMeasurementValid=False,interprocessTransportUsed=True,physicalTransferQualified=False,
            independentNumericalComparisonPerformed=False,profile=a.PROFILE,profileFingerprint=summary['profileFingerprint'],
            agreementFingerprint=agreement_fp,identity=identities[rank],readiness=rank_wire.readiness(a, agreement_fp),
            frames=x.get('frames'),actions=rank_trace.expected_actions(rank,policy),selectedTokenID=baseline['argmaxTokenID'],
            exactTokenPacketJSON=x.get('exactTokenPacketJSON'),tokenPacketFingerprint=x.get('tokenPacketFingerprint'),
            tokenPacketWireBytesSHA256=x.get('tokenPacketWireBytesSHA256'),finalDigest=x.get('finalDigest'),
            completedFrames=16,committedTokens=8192,preparedAheadFrames=15 if rank==0 and policy==rank_trace.POLICIES[1] else 0,
            releasedOriginalBoundaryHandles=16,postStopReleaseCompleted=True,allRequestStateRetired=True,
            originalWrapperReleaseIsNotProofOfNoStorageAliases=True)
        if rank == 0: expected['timing'] = x.get('timing')
        else: expected['localSelection'] = pair_wire.token(identities[rank], summary, recorded['steps'][-1]['frame'])
        a.require(set(x) == set(expected), 'Execution fields/optional rank roles differ')
        for key in expected:
            if key not in ('frames','exactTokenPacketJSON','tokenPacketFingerprint','tokenPacketWireBytesSHA256','finalDigest','timing'):
                a.exact(x[key], expected[key], 'rank execution '+str(rank)+'.'+key)
    frames = rank_wire.check_frames(a, pair_wire, [x['frames'] for x in executions], recorded, summary, loads, identities, agreement_fp)
    token = rank_wire.check_token(a, executions, dict(value=descriptor,fingerprint=agreement_fp), summary, frames[-1])
    final_state_sha = final.check_finals(a, [x['finalDigest'] for x in executions], reference, summary, loads, identities, agreement_fp)
    diagnostic_timing = rank_trace.check_timing(a, executions[0]['timing'])
    return dict(status='passed',scope='registered9b_long_prefill_8192_chunk512_output1_cut12_v4_rank_pair',
        epoch=epoch,schedulingPolicy=policy,profile=a.PROFILE,profileFingerprint=summary['profileFingerprint'],
        promptFileSHA256=expected_prompt_sha256,promptTokenIDsSHA256=summary['promptTokenIDsSHA256'],
        requestFingerprint=simple,recordedRequestFingerprint=history,agreementFingerprint=agreement_fp,
        baselineReferenceFingerprint=baseline['referenceFingerprint'],baselineRequestFingerprint=baseline['requestFingerprint'],
        baselineRecordedRequestFingerprint=baseline['recordedRequestFingerprint'],
        arithmeticEnvironmentSHA256=baseline['arithmeticEnvironmentSHA256'],sourceInventory=inventory,
        frameCount=16,nativeCommitAssertions=32,committedTokensPerRank=[8192,8192],actionCounts=[204,235],
        preparedAheadFrames=[executions[0]['preparedAheadFrames'],0],releasedOriginalBoundaryHandles=[16,16],
        completeFinalStateComponents=72,finalStateLogicalBytes=319946784,finalStateSHA256=final_state_sha,
        independentlyReconstructedOffsetComponents=8,opaqueNumericalStateComponents=64,
        baselineFinalLogits=baseline['finalLogits'],baselineReconstructedNativeLogitBytes=496640,
        candidateRawLogitValuesExported=False,candidateNativeBytesIndependentlyReconstructed=False,
        candidateLogitMetadataAndDigestExact=True,candidateStateMetadataAndDigestsExact=True,
        selectedTokenID=baseline['argmaxTokenID'],baselineMaximumLogit=baseline['maximumLogit'],
        baselineMaximumTieCount=baseline['maximumTieCount'],frames=frames,token=token,
        timing=diagnostic_timing,memoryByRank=[memory(a,r['memory']) for r in reports],
        throughputQualified=False,physicalTransferQualified=False,independentModelForwardPerformed=False,
        limitations=[
            'The frozen full-model reference row is reconstructed from exported Float values as native BF16 bytes, preserving signed zero. Candidate logits export only metadata and a digest; no candidate raw-byte comparison or second independent model forward is performed.',
            'All72 candidate global-state entries, geometries and digests match the reference union; only eight Int32 offsets are reconstructable. The64 numerical-state digests and all16 boundary payload digests are opaque. Coherent fabricated payload digests cannot be disproved without payloads.',
            'Exact encoded v4 envelopes and token packets match both ranks and locally derived request/source expectations. Ready/received/consumed and post-stop ACK byte hashes are independently derived expectations; actual ACK bytes and readiness/start payloads are not exported.',
            'Scalar traces exactly match source phase placement and serial/lookahead preparation order. They are source-bound native assertions, not independent scheduler observations, proof of concurrency, timestamps per phase, or physical-transfer evidence.',
            'Actual loading, wrapper release, native selection/commits, retirement and early arithmetic environment application require executable/archive/runtime provenance. Source descriptor digest is opaque; active and inert mappings/bytes are checked against pinned headers and a frozen Foundation plan control.',
            'Timing is one origin monotonic diagnostic interval, source-bound to final consumed/token validation and excluding final capture/retirement. No throughput, representative workload, stable timing or cluster speedup is qualified.',
            'Memory records are cumulative native MLX allocator observations, not RSS, process peak, resource-gate or no-alias proofs. Admission byte budget omits weights, workspaces and other process allocations.'])


def validate(paths, baseline_path, prompt_path, expected_prompt_sha256, epoch, policy,
             expected_pair_sha256, pair_cpu_receipt_path, expected_pair_cpu_receipt_sha256):
    """The new container/pins are explicit; old standalone evidence is refused."""
    from audit_cut12_ranks import validate as validate_files
    return validate_files(paths,baseline_path,prompt_path,expected_prompt_sha256,epoch,policy,
        expected_pair_sha256,pair_cpu_receipt_path,expected_pair_cpu_receipt_sha256)
