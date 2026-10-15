"""Bounded result/queue declarations; full action replay remains an independent audit."""
import re
from stage_lookahead_inputs import recorded_request_fingerprint

FLOW='prompt_lookahead_one_v1'
ENVELOPE_VERSION=2


def bounded(value,low,high):
    if type(value)is not int or not low<=value<=high:raise ValueError('Invalid lookahead integer counter')
    return value


def text(value):
    if type(value)is not str or not 1<=len(value.encode('utf8'))<=96:raise ValueError('Invalid bounded action/activity')


def validate_execution(execution,rank,epoch,inputs):
    required={'kind','flow','identity','recordedRequestFingerprint','decodeAdmission','completions','actions',
        'finalCommittedTokens','completedFrames','maximumExplicitNativeBoundarySlots','releasedOriginalArrayHandles',
        'allRequestStateRetired'}
    sender={'producedFrames','receivedFrames','promptLookaheadCount','maximumProducedMinusReceived',
            'maximumReceivedMinusCompleted','maximumProducedMinusCompleted'}
    if not isinstance(execution,dict) or set(execution)!=(required|sender if rank==0 else required):
        raise ValueError('Lookahead execution schema/rank responsibilities differ')
    if execution['kind']!='qwen_layer_stage_lookahead_request' or execution['flow']!=FLOW:
        raise ValueError('Wrong lookahead execution namespace/flow')
    if execution['recordedRequestFingerprint']!=recorded_request_fingerprint(epoch,inputs['prompt'],inputs['teacher']):
        raise ValueError('Lookahead recorded input fingerprint differs')
    if execution['decodeAdmission']!='frozen_teacher_diagnostic' or execution['allRequestStateRetired']is not True:
        raise ValueError('Lookahead teacher policy/retirement differs')
    for key,value in [('finalCommittedTokens',68),('completedFrames',6),('releasedOriginalArrayHandles',6)]:
        if bounded(execution[key],0,68)!=value:raise ValueError('Lookahead completion counter differs: '+key)
    bounded(execution['maximumExplicitNativeBoundarySlots'],0,1)
    if rank==0:
        for key,value in [('producedFrames',6),('receivedFrames',6),('promptLookaheadCount',2)]:
            if bounded(execution[key],0,6)!=value:raise ValueError('Lookahead sender summary differs: '+key)
        for key,limit in [('maximumProducedMinusReceived',1),('maximumReceivedMinusCompleted',1),('maximumProducedMinusCompleted',2)]:
            bounded(execution[key],0,limit)
    actions=execution['actions']
    if not isinstance(actions,list) or not 1<=len(actions)<=24*6+8:raise ValueError('Missing/unbounded lookahead actions')
    for index,item in enumerate(actions):
        required={'ordinal','action','scheduleActivity','nativeCommittedTokens','completedFrames',
                  'explicitNativeBoundarySlots','pendingConsumedFrameSlots'}
        required|={'producedFrames','receivedFrames'} if rank==0 else {'receiverCommittedFrames'}
        if not isinstance(item,dict) or not required<=set(item)<=required|{'frameSequence','headerSHA256'}:
            raise ValueError('Lookahead action scalar schema differs')
        if bounded(item['ordinal'],0,151)!=index:raise ValueError('Action ordinals are not complete and ordered')
        text(item['action']);text(item['scheduleActivity']);bounded(item['nativeCommittedTokens'],0,68)
        for key in ('completedFrames','producedFrames','receivedFrames','receiverCommittedFrames'):
            if key in item:bounded(item[key],0,6)
        for key in ('explicitNativeBoundarySlots','pendingConsumedFrameSlots'):bounded(item[key],0,1)
        if 'frameSequence'in item:bounded(item['frameSequence'],0,5)
        if 'headerSHA256'in item and (type(item['headerSHA256'])is not str or re.fullmatch('[0-9a-f]{64}',item['headerSHA256'])is None):
            raise ValueError('Malformed action header digest')
    frames=execution['completions']
    if not isinstance(frames,list) or len(frames)!=6:raise ValueError('Expected six lookahead completions')
    return frames
