"""Numerical comparison only. Root separately joins actual driver/cleanup/resource
receipts; supplied expected IDs/builds are not production membership authority."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import struct
import uuid

REFERENCE_RESULT_SHA = '8a808a8c2a065719442b2eb1a951b5f09dc03cfdb3250403e2a79b0a51d4ae4b'
REFERENCE_STDOUT_SHA = '4ea4336638b38caa3b4e5dcac10a56aa7de398c756254ea50529918c311d32bd'
RESOURCE_POLICY_SHA = 'dc910813838e3d06a7fcdc1a93ee3b2e8529247839048bff84f50353fb052db5'
PROTECTED_BYTES = 196_788_480
SIDE_FIELDS = set(('schema nativeRequestID membershipEpoch rank sourceLayerStart sourceLayerEnd requestFingerprint '
    'profileFingerprint agreementFingerprint sourceConfigurationSHA256 artifactAggregateSHA256 storageCommitmentSHA256 '
    'planFingerprint numericalPolicySHA256 protectedResourcePolicySHA256 stageFingerprints rankBuildSHA256 '
    'promptTokenIDsSHA256 promptCount chunkSize outputCount prefillSchedule stopTokenIDs selectedTokenIDs '
    'selectedTokenIDsSHA256 tokenChainSHA256 completedFrames committedTokens finishReason bothRequestStatesRetired '
    'logicalStateBytes stageStateSHA256 stateEntries finalLogits captureBudget captureResourceObservationCount '
    'minimumCaptureActualFreeBytes minimumCaptureAllocatorLimitBytes correctnessOnly throughputMeasurementValid '
    'stateBytesIncluded intermediateLogitRowsCompared independentNumericalComparisonPerformed '
    'ownerCleanupIndependentlyVerified wholeProcessPeakProven servingEnabled').split())

def require(condition, message):
    if not condition: raise ValueError(message)

def digest(raw): return hashlib.sha256(raw).hexdigest()
def pin(value):
    require(type(value) is str and len(value) == 64 and all(c in '0123456789abcdef' for c in value), 'invalid SHA256')

def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key'); result[key] = value
        return result
    def invalid(value): raise ValueError('nonfinite JSON literal: ' + value)
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)

def token_hash(tokens): return digest(','.join(str(x) for x in tokens).encode())

def state_fingerprint(entries):
    # Same established CBv2 global-component convention as reference_state.py.
    rows = ['cbv2-owned-state-v1', 'tokens=33']
    rows += ['{}|{}|{}|{}|{}|{}'.format(e['globalLayerIndex'], e['component'], e['shape'],
             e['dtype'], e['byteCount'], e['sha256']) for e in entries]
    return digest('\n'.join(rows).encode())

def state_entry(entry):
    require(type(entry) is dict and set(entry) == {'globalLayerIndex','component','shape','dtype','byteCount','sha256'}, 'closed state component fields')
    require(type(entry['globalLayerIndex']) is int and 0 <= entry['globalLayerIndex'] < 32,
            'invalid global layer index')
    require(type(entry['component']) is str and entry['component'] in
            ('conv','ssm','kv.keys','kv.values','kv.position_offsets'), 'invalid state component')
    require(type(entry['shape']) is list and 0 < len(entry['shape']) <= 4
            and all(type(v) is int and v > 0 for v in entry['shape']), 'invalid state shape')
    require(type(entry['dtype']) is str and entry['dtype'] in ('bfloat16','float32','int32'), 'invalid state dtype')
    require(type(entry['byteCount']) is int and entry['byteCount'] > 0, 'invalid state bytes')
    pin(entry['sha256'])

def logical_row(row):
    require(type(row) is dict and set(row) == {'shape', 'dtype', 'byteCount', 'logicalBytesSHA256', 'values'}, 'full row fields')
    require(type(row['shape']) is list and all(type(v) is int for v in row['shape'])
            and row['shape'] == [1, 248320] and row['dtype'] == 'bfloat16'
            and type(row['byteCount']) is int and row['byteCount'] == 496640, 'full row geometry')
    pin(row['logicalBytesSHA256'])
    values = row['values']
    require(type(values) is list and len(values) == 248320, 'missing vocabulary values')
    raw = bytearray()
    for value in values:
        require(type(value) in (int, float) and math.isfinite(value), 'nonfinite/non-numeric logit')
        bits = struct.pack('<f', value)
        require(bits[:2] == b'\0\0', 'value is not exactly representable as the reported BF16')
        raw.extend(bits[2:])
    require(digest(raw) == row['logicalBytesSHA256'], 'full row values disagree with native logical-byte hash')
    return bytes(raw)

def compare(reference, sides, expected):
    require(set(expected) == {'publicRequestID', 'nativeRequestID', 'membershipEpoch', 'rankBuildSHA256', 'resourcePolicySHA256'}, 'expected driver join fields')
    for name in ('publicRequestID', 'nativeRequestID', 'membershipEpoch'):
        require(str(uuid.UUID(expected[name])) == expected[name], 'noncanonical original driver identity')
    # The pinned ordinary Swift UUID encoder writes uppercase. The native
    # protected agreement and retained driver use canonical lowercase strings.
    require(reference['requestID'] == expected['publicRequestID'].upper(), 'public request differs from actual reference')
    require(expected['resourcePolicySHA256'] == RESOURCE_POLICY_SHA, 'unqualified numerical policy')
    require(type(expected['rankBuildSHA256']) is list and len(expected['rankBuildSHA256']) == 2, 'two native builds required')
    for value in expected['rankBuildSHA256']: pin(value)
    require(reference['promptCount'] == 32 and reference['chunkSize'] == 16 and reference['requestedOutputCount'] == 2
            and reference['committedTokens'] == 33 and reference['completedFrames'] == 3
            and reference['allRequestStateRetired'] is True and reference['stopTokenIDs'] == [], 'reference request geometry/retirement')
    require(type(sides) is list and len(sides) == 2, 'both actual ranks required')
    joined = []
    for rank, side in enumerate(sides):
        require(type(side) is dict and set(side) == SIDE_FIELDS, 'closed candidate evidence fields')
        require(side['schema'] == 'qwen9b_protected_final_evidence_v1' and type(side['rank']) is int and side['rank'] == rank, 'rank/schema')
        require(side['nativeRequestID'] == expected['nativeRequestID'] and side['membershipEpoch'] == expected['membershipEpoch'], 'actual native UUID/epoch differs')
        require(side['rankBuildSHA256'] == expected['rankBuildSHA256'] and side['protectedResourcePolicySHA256'] == RESOURCE_POLICY_SHA, 'actual runtime/policy differs')
        require(side['sourceLayerStart'] == rank * 16 and side['sourceLayerEnd'] == (rank + 1) * 16, 'cut16 ownership')
        require(type(side['sourceLayerStart']) is int and type(side['sourceLayerEnd']) is int, 'integer layer bounds')
        for key in ('requestFingerprint','profileFingerprint','agreementFingerprint','sourceConfigurationSHA256',
                    'artifactAggregateSHA256','storageCommitmentSHA256','planFingerprint','numericalPolicySHA256',
                    'promptTokenIDsSHA256','selectedTokenIDsSHA256','tokenChainSHA256','stageStateSHA256'): pin(side[key])
        require(type(side['stageFingerprints']) is list and len(side['stageFingerprints']) == 2, 'both stage fingerprints required')
        for value in side['stageFingerprints']: pin(value)
        for key, value in [('promptCount',32), ('chunkSize',16), ('outputCount',2), ('completedFrames',3),
                           ('committedTokens',33), ('prefillSchedule','serial_v1'), ('finishReason','length'), ('stopTokenIDs',[])]:
            require(side[key] == value and type(side[key]) is type(value), 'candidate geometry: ' + key)
        require(side['bothRequestStatesRetired'] is True and side['correctnessOnly'] is True
                and side['throughputMeasurementValid'] is False and side['stateBytesIncluded'] is False
                and side['intermediateLogitRowsCompared'] is False and side['independentNumericalComparisonPerformed'] is False
                and side['ownerCleanupIndependentlyVerified'] is False and side['wholeProcessPeakProven'] is False
                and side['servingEnabled'] is False, 'candidate must retain qualification boundaries')
        source = reference['source']
        for key, other in [('sourceConfigurationSHA256','sourceConfigurationSHA256'), ('artifactAggregateSHA256','artifactAggregateSHA256'),
                           ('planFingerprint','planSHA256'), ('numericalPolicySHA256','arithmeticEnvironmentSHA256')]:
            require(side[key] == source[other], 'reference/candidate source differs: ' + key)
        require(side['promptTokenIDsSHA256'] == reference['promptTokenIDsSHA256'], 'prompt IDs differ')
        require(side['profileFingerprint'] == reference['profile']['fingerprint'], 'ordinary generation profile differs')
        require(side['selectedTokenIDs'] == reference['selectedTokenIDs'] and len(side['selectedTokenIDs']) == 2
                and all(type(v) is int for v in side['selectedTokenIDs']), 'greedy IDs differ')
        require(side['selectedTokenIDsSHA256'] == token_hash(side['selectedTokenIDs']), 'token hash differs')
        calculated = digest(('qwen-stage-generation-request-v1\n' + side['profileFingerprint'] + '\n'
            + expected['nativeRequestID'] + '\nprompt=' + reference['promptTokenIDsSHA256']
            + '\nchunk=16\noutput=2\nstop=').encode())
        require(side['requestFingerprint'] == calculated, 'original native request fingerprint differs')
        entries = side['stateEntries']; original = [e for e in reference['finalState']['entries'] if rank*16 <= e['globalLayerIndex'] < (rank+1)*16]
        require(type(entries) is list and len(entries) == 36 and entries == original, 'component metadata/value digest differs')
        for entry in entries: state_entry(entry)
        require(type(side['logicalStateBytes']) is int and side['logicalStateBytes'] == sum(e['byteCount'] for e in entries)
                and side['stageStateSHA256'] == state_fingerprint(entries), 'stage state summary differs')
        joined += entries
        charge = side['captureBudget']
        require(type(charge) is dict and set(charge) == set(('originalRequestReservedBytes logicalRowBytes float32RowBytes '
            'extraHostBytes extraNativeBytes protectedReservedBytes exportHostAllowanceBytes maximumEncodedBytes totalReservedBytes').split()), 'closed capture budget fields')
        require(charge['protectedReservedBytes'] == PROTECTED_BYTES and charge['exportHostAllowanceBytes'] == 10*1048576
                and charge['maximumEncodedBytes'] == 8*1048576, 'export allowance differs')
        require(all(type(charge[key]) is int and charge[key] >= 0 for key in charge), 'invalid resource byte count')
        require(charge['totalReservedBytes'] == charge['originalRequestReservedBytes'] + charge['extraHostBytes']
                + charge['extraNativeBytes'] + PROTECTED_BYTES and charge['originalRequestReservedBytes'] > 0, 'combined reservation differs')
        require(charge['logicalRowBytes'] == rank*496640 and charge['float32RowBytes'] == rank*993280
                and charge['extraHostBytes'] == rank*1489920 and charge['extraNativeBytes'] >= rank*1489920
                and (rank == 1 or charge['extraNativeBytes'] == 0), 'asymmetric capture charge differs')
        require(type(side['captureResourceObservationCount']) is int and side['captureResourceObservationCount'] > 0
                and type(side['minimumCaptureActualFreeBytes']) is int and type(side['minimumCaptureAllocatorLimitBytes']) is int
                and side['minimumCaptureActualFreeBytes'] >= 6*1024**3 and side['minimumCaptureAllocatorLimitBytes'] > 0, 'capture resource observations missing')
    require(sides[0]['finalLogits'] is None, 'rank0 unexpectedly owns final head output')
    for key in ('agreementFingerprint','requestFingerprint','profileFingerprint','storageCommitmentSHA256','planFingerprint','stageFingerprints','tokenChainSHA256'):
        require(sides[0][key] == sides[1][key], 'peer agreement differs: ' + key)
    require(len(joined) == 72 and joined == reference['finalState']['entries']
            and state_fingerprint(joined) == reference['finalState']['fingerprint'], 'full72-state join differs')
    require(logical_row(sides[1]['finalLogits']) == logical_row(reference['finalLogits']), 'full final vocabulary row differs')
    final_values = sides[1]['finalLogits']['values']
    require(final_values.index(max(final_values)) == sides[1]['selectedTokenIDs'][-1], 'final row does not select the committed greedy token')
    return dict(numericalComparisonPassed=True, comparedStateEntries=72, comparedVocabularyValues=248320,
                selectedTokenIDs=reference['selectedTokenIDs'], nativeRequestID=expected['nativeRequestID'],
                membershipEpoch=expected['membershipEpoch'], finalStateFingerprint=reference['finalState']['fingerprint'],
                finalLogitsSHA256=reference['finalLogits']['logicalBytesSHA256'], throughputQualified=False,
                ownerCleanupQualified=False, membershipAuthorityQualified=False, servingEnabled=False)

def pinned(path, expected, maximum):
    pin(expected); path = Path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= maximum, 'bounded regular input required')
        chunks=[]; count=0
        while True:
            chunk=os.read(fd,65536)
            if not chunk: break
            count+=len(chunk);require(count<=maximum,'input grew');chunks.append(chunk)
        raw=b''.join(chunks);after=os.fstat(fd)
        require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)==
                (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)
                and digest(raw)==expected,'input changed or hash differs')
        return raw
    finally: os.close(fd)

def main():
    p=argparse.ArgumentParser()
    for name in ('reference-result','reference-stdout','expected','rank0','rank1','output'):p.add_argument('--'+name,required=True)
    for name in ('expected','rank0','rank1'):p.add_argument('--'+name+'-sha256',required=True)
    a=p.parse_args()
    reference_result=strict_json(pinned(a.reference_result,REFERENCE_RESULT_SHA,65536))
    records=[strict_json(line) for line in pinned(a.reference_stdout,REFERENCE_STDOUT_SHA,16*1024**2).splitlines() if line]
    require(len(records)==2,'actual reference record count changed')
    reference=records[1]['execution']
    require(reference_result['referenceCompleted'] is True and reference_result['selectedTokenIDs']==reference['selectedTokenIDs']
            and reference_result['finalLogitsSHA256']==reference['finalLogits']['logicalBytesSHA256']
            and reference_result['finalStateFingerprint']==reference['finalState']['fingerprint'],'reference summary join differs')
    result=compare(reference,[strict_json(pinned(a.rank0,a.rank0_sha256,8*1024**2)),strict_json(pinned(a.rank1,a.rank1_sha256,8*1024**2))],
                   strict_json(pinned(a.expected,a.expected_sha256,65536)))
    result.update(referenceResultSHA256=REFERENCE_RESULT_SHA,referenceStdoutSHA256=REFERENCE_STDOUT_SHA,
                  expectedDriverJoinSHA256=a.expected_sha256,rankSidecarSHA256=[a.rank0_sha256,a.rank1_sha256])
    with open(a.output,'x') as f:json.dump(result,f,sort_keys=True,indent=2);f.write('\n')

if __name__=='__main__':main()
