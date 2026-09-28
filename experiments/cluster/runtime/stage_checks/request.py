"""One bounded teacher-forced request, independent of artifact/model size."""
import uuid
from .common import canonical,digest,exact,integer,require


def steps(prompt,teacher,chunk):
    integer(len(prompt),1,128);integer(len(teacher),0,3);integer(chunk,1,32)
    result=[];offset=0
    while offset<len(prompt):
        tokens=prompt[offset:offset+chunk]
        frame=dict(sequence=len(result),phase='prefill',tokenOffset=offset,tokenCount=len(tokens),
                   finalPromptChunk=offset+len(tokens)==len(prompt))
        result.append(dict(frame=frame,tokenIDs=tokens));offset+=len(tokens)
    for token in teacher:
        result.append(dict(frame=dict(sequence=len(result),phase='decode',tokenOffset=offset,
                                      tokenCount=1,finalPromptChunk=False),tokenIDs=[token]));offset+=1
    return result


def make_request(epoch,prompt,teacher,chunk,vocabulary):
    integer(vocabulary,4,262144)
    for token in prompt+teacher:integer(token,0,vocabulary-1)
    sequence=steps(prompt,teacher,chunk)
    request=dict(requestID=str(uuid.UUID(hex=epoch)),promptCount=len(prompt),chunkSize=chunk,outputCount=len(teacher)+1)
    simple=digest(f"qwen-stage-request-v1|{request['requestID']}|{len(prompt)}|{chunk}|{len(teacher)+1}".encode())
    recorded=digest('\n'.join(['qwen-layer-stage-recorded-request-v1',simple,f'vocabulary={vocabulary}',
                               'prompt='+','.join(map(str,prompt)),'teacher='+','.join(map(str,teacher))]).encode())
    return dict(request=request,vocabularySize=vocabulary,promptTokenIDs=prompt,teacherTokenIDs=teacher,
                steps=sequence,fingerprint=recorded),simple


def validate(actual,expected):
    require(set(actual)==set(expected),'Recorded request keys differ')
    # UUID JSON spelling is case-insensitive; its fingerprint uses lowercase.
    normalized=dict(actual,request=dict(actual['request'],requestID=actual['request']['requestID'].lower()))
    exact(normalized,expected,'Recorded request/history/schedule differs')


def baseline_history(actual,expected):
    require(actual['request']['requestID'].lower()!=expected['request']['requestID'].lower(),
            'Baseline must be an independently recorded request, not this cohort record')
    comparable=dict(actual,request=dict(actual['request'],requestID=expected['request']['requestID']),fingerprint=expected['fingerprint'])
    validate(comparable,expected)
