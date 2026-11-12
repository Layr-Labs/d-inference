"""Exact prior fabricated numerical builders, not observed native values."""
import copy
import struct
from binding_oracle import load
audit, contract = load()
from outer_fixture import rows, raw, TOKENS, PROFILE, PROMPT, TEACHER

def reseal(values):
    baseline=values[0]['baseline'];comparison=values[1]['pair']['comparison']
    for original,candidate in zip(baseline['frames'],comparison['frames']):
        state=original['state'];state['logicalByteCount']=sum(x['byteCount'] for x in state['entries'])
        state['fingerprint']=audit.state_digest(state)
        candidate.update(stateEntriesCompared=len(state['entries']),logicalStateBytesPerSide=state['logicalByteCount'],globalStateSHA256=state['fingerprint'])
    baseline['fingerprint']=audit.baseline_digest(baseline)
    comparison['baselineEvidenceSHA256']=baseline['fingerprint'];values[1]['baselineEvidenceSHA256']=baseline['fingerprint']

def numeric_fixture(profile):
    values=rows(profile);e=audit.expected(profile);layout=e['sourceParameterLayoutSHA256']
    baseline=values[0]['baseline'];comparison=values[1]['pair']['comparison']
    baseline['source']['sourceParameterLayoutSHA256']=layout;comparison['source']['sourceParameterLayoutSHA256']=layout
    values[0]['load'].update(parameterLayoutSHA256=layout,sourceTensorCount=e['tensorCount'],largestHostTensorBytes=e['largestTensorBytes'])
    for stage in values[1]['pair']['stageLoads']:stage['sourceParameterLayoutSHA256']=layout
    numbers=[0.0]*248320;numbers[0]=-0.0;numbers[1]=0.5;numbers[2]=-2.0
    data=b'\x00\x80\x00\x3f\x00\xc0'+b'\0\0'*(248320-3)
    record=dict(shape=[1,248320],dtype='bfloat16',byteCount=len(data),logicalBytesSHA256=audit.digest(data),values=numbers)
    for i,frontier in enumerate([2,3,4]):
        entries=[]
        for geometry in audit.state_geometry(e,frontier):
            identity=audit.digest(struct.pack('<i',frontier)) if geometry['component']=='kv.position_offsets' else audit.digest(('invented|'+str(frontier)+'|'+str(geometry)).encode())
            entries.append(dict(geometry,sha256=identity))
        baseline['frames'][i]['state']=dict(committedTokens=frontier,entries=entries,logicalByteCount=0,fingerprint='0'*64)
        if i:
            baseline['frames'][i]['logits']=copy.deepcopy(record)
            comparison['frames'][i]['logits']=copy.deepcopy(record)
    reseal(values);return values
