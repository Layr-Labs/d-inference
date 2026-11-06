"""Compare exact final metadata/digests; candidate values are unavailable."""
import math
from cut12_pair_storage import compute_source


def logits_metadata(identity, summary, frame):
    return dict(kind='qwen_layer_stage_prefill_final_logits', identity=identity,
        recordedRequestFingerprint=summary['recordedRequestFingerprint'], frame=frame,
        committedTokens=8192, vocabularySize=248320, **summary['finalLogits'])


def final_fingerprint(a, record):
    row = a.sha(a.canonical(record['finalLogits'])) if 'finalLogits' in record else 'no-logits'
    return a.sha('\n'.join(['qwen-layer-stage-profiled-prefill-final-digest-v1', record['agreementFingerprint'],
        record['profile'], record['profileFingerprint'], record['recordedRequestFingerprint'],
        a.sha(a.canonical(record['identity'])), a.sha(a.canonical(record['source'])),
        record['finalState']['fingerprint'], row]).encode())


def expected_final(a, rank, reference, summary, load, identity, agreement_fp):
    a.require(type(rank) is int and rank in (0,1),'Invalid selected stage')
    a.exact(load['planSHA256'],a.selection['planFingerprint'],'Final source Plan differs from selected range')
    start, end = a.selection['ranges'][rank]
    entries = [e for e in reference['execution']['finalState']['entries'] if start <= e['globalLayerIndex'] < end]
    expected={}
    for layer in a.selection['states'][rank]:
        global_index=layer['layer']['globalIndex']
        for component in layer['components']:
            if component in ('kv.keys','kv.values'):shape,dtype,width=[1,4,8192,256],'bfloat16',2
            elif component=='kv.position_offsets':shape,dtype,width=[1],'int32',4
            elif component=='conv':shape,dtype,width=[1,3,8192],'bfloat16',2
            elif component=='ssm':shape,dtype,width=[1,32,128,128],'float32',4
            else:raise ValueError('Unknown selected state component')
            key=(global_index,component);a.require(key not in expected,'Duplicate selected state owner')
            expected[key]=(shape,dtype,math.prod(shape)*width)
    a.require(len(entries)==len(expected) and {(e['globalLayerIndex'],e['component']) for e in entries}==set(expected),
              'Stage state coverage differs')
    for entry in entries:
        a.exact([entry['shape'],entry['dtype'],entry['byteCount']],list(expected[(entry['globalLayerIndex'],entry['component'])]),
                'Selected reference state geometry differs')
    byte_count = sum(e['byteCount'] for e in entries)
    state = dict(committedTokens=8192, entries=entries, logicalByteCount=byte_count, fingerprint=a.state_fingerprint(entries))
    record = dict(kind='qwen_layer_stage_profiled_prefill_final_digest', schemaVersion=1,
        correctnessOnly=True, throughputMeasurementValid=False, modelForwardCompared=False, physicalTransferQualified=False,
        nativeLogitBytesCompared=False, fullVocabularyValuesExported=False, requestStateRetirementStillRequired=True,
        externalPostStopOrderingStillRequired=True, profile=a.PROFILE, profileFingerprint=summary['profileFingerprint'],
        agreementFingerprint=agreement_fp, identity=identity, recordedRequestFingerprint=summary['recordedRequestFingerprint'],
        source=compute_source(a, rank, load, summary), completedFrames=16, committedTokens=8192,
        finalState=state, perFrameStateCaptures=0, perFrameLogitCaptures=0, finalStateCaptures=1,
        finalLogitCaptures=rank, nativeTokenSelections=rank)
    if rank == 1:
        record['finalLogits'] = logits_metadata(identity, summary, reference['execution']['request']['steps'][-1]['frame'])
    record['fingerprint'] = final_fingerprint(a, record)
    return record


def check_finals(a, actual, reference, summary, loads, identities, agreement_fp):
    a.require(type(actual) is list and len(actual) == 2, 'Exactly two final stage digests required')
    for rank in range(2):
        a.exact(actual[rank], expected_final(a, rank, reference, summary, loads[rank], identities[rank], agreement_fp),
                'stage final digest ' + str(rank))
    entries = sorted([e for r in actual for e in r['finalState']['entries']], key=lambda e:(e['globalLayerIndex'],e['component']))
    a.exact(entries, reference['execution']['finalState']['entries'], 'disjoint complete final state union')
    a.require(len(entries) == len({(e['globalLayerIndex'],e['component']) for e in entries}) == 72,
              'Repeated or missing final state owner')
    return a.state_fingerprint(entries)
