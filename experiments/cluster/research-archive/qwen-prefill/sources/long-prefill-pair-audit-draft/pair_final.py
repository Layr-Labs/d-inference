"""Compare exact final metadata/digests; candidate values are unavailable."""
from pair_storage import compute_source


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
    entries = [e for e in reference['execution']['finalState']['entries'] if rank * 16 <= e['globalLayerIndex'] < (rank + 1) * 16]
    a.require(len(entries) == 36 and sum(e['byteCount'] for e in entries) == 159973392, 'Stage state coverage differs')
    state = dict(committedTokens=8192, entries=entries, logicalByteCount=159973392, fingerprint=a.state_fingerprint(entries))
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
