"""Independent CPU recipe for source-derived v4 and unchanged legacy vectors.

No Swift, model, transport or candidate output is executed/read. The optional
writer creates new vector/check files exclusively; prior evidence is preserved.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path

PROFILE = 'long_prefill_8k_v1'
FLOW = 'profiled_prefill_measurement_v1'
SELECTION = 'mlx_argmax_all_axes_with_finite_guard_v1'
REQUEST_ID = '00000000-0000-0000-0000-000000000001'
DOMAINS = dict(agreement='qwen-profiled-prefill-start-agreement-v1', start='qwen-profiled-prefill-start-packet-v1',
    boundary='qwen-profiled-prefill-boundary-envelope-v1', token='qwen-profiled-prefill-first-token-packet-v1',
    ack='qwen-stage-profiled-ack-v4', post_stop='qwen-profiled-prefill-post-stop-v1')


def sha(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def fingerprint(domain, value):
    return sha(domain.encode() + b'\n' + value)


def vector(value, domain=None):
    raw = canonical(value)
    return dict(encodedBase64=base64.b64encode(raw).decode(), byteCount=len(raw), wireBytesSHA256=sha(raw),
                fingerprint=fingerprint(domain, raw) if domain else sha(raw), content=value)


def make(profiled):
    prompt_count, chunk = (8192, 512) if profiled else (65, 32)
    ids = [i % 256 for i in range(prompt_count)]
    joined = ','.join(map(str, ids))
    source = dict(sourceConfigurationSHA256='a'*64, artifactAggregateSHA256='b'*64,
                  storageCommitmentSHA256='c'*64, planFingerprint='d'*64, producerStageFingerprint='e'*64)
    if profiled:
        profile_material = '\n'.join(['qwen-stage-prefill-profile-v1', PROFILE, 'batch=1', 'prompt=1...8192',
            'chunk=1...512', 'output=1', 'teacher=0', 'frames=1...128', 'hidden=1...8192',
            'vocabulary=1...262144', 'floatingDTypes=float16,bfloat16,float32'])
        profile_fp = sha(profile_material)
        assert profile_fp == '2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b'
        request_fp = sha('\n'.join(['qwen-stage-profiled-prefill-request-v1',PROFILE,profile_fp,REQUEST_ID,
                                   'batch=1',f'prompt={prompt_count}',f'chunk={chunk}','output=1']))
        recorded_fp = sha('\n'.join(['qwen-layer-stage-profiled-prefill-recorded-request-v1',PROFILE,
            profile_fp,request_fp,'vocabulary=256','prompt='+joined,'teacher=']))
    else:
        request_fp = sha(f'qwen-stage-request-v1|{REQUEST_ID}|65|32|1')
        recorded_fp = sha('\n'.join(['qwen-layer-stage-recorded-request-v1',request_fp,
                                    'vocabulary=256','prompt='+joined,'teacher=']))
    frame_count = (prompt_count-1)//chunk+1
    descriptor = dict(version=4 if profiled else 3,flow=FLOW if profiled else 'bounded_prefill_measurement_v1',
        schedulingPolicy='serial_v1',epoch='1'*32,requestID=REQUEST_ID,requestFingerprint=request_fp,
        recordedRequestFingerprint=recorded_fp,promptCount=prompt_count,chunkSize=chunk,outputCount=1,batchSize=1,
        frameCount=frame_count,promptTokenIDsSHA256=sha(joined),**source,consumerStageFingerprint='f'*64,
        producerConstructionConfigurationSHA256='2'*64,consumerConstructionConfigurationSHA256='3'*64,
        bf16ConversionEnabled=False,hiddenSize=128,nativeDType='bfloat16',logitsDType='bfloat16',
        vocabularySize=256,selectionPolicy=SELECTION)
    if profiled:descriptor.update(profile=PROFILE,profileFingerprint=profile_fp,arithmeticEnvironmentSHA256='5'*64)
    agreement_fp = fingerprint(DOMAINS['agreement'] if profiled else 'qwen-prefill-start-agreement-v1', canonical(descriptor))
    sequence=frame_count-1; offset=sequence*chunk; count=prompt_count-offset
    frame=dict(sequence=sequence,phase='prefill',tokenOffset=offset,tokenCount=count,finalPromptChunk=True)
    inner=dict(version=2 if profiled else 1,requestFingerprint=request_fp,**source,frame=frame,
        tokenIDsSHA256=sha(','.join(map(str,ids[offset:]))),payloadSHA256='4'*64,shape=[1,count,128],
        dtype='bfloat16',byteCount=count*128*2)
    if profiled:inner.update(profile=PROFILE,profileFingerprint=profile_fp,recordedRequestFingerprint=recorded_fp)
    common=dict(version=descriptor['version'],flow=descriptor['flow'],agreementFingerprint=agreement_fp)
    start=vector(dict(common,kind='start',agreement=descriptor),DOMAINS['start'] if profiled else None)
    boundary=vector(dict(common,kind='boundary',boundary=inner),DOMAINS['boundary'] if profiled else None)
    token=dict(common,kind='first_selected_token',epoch='1'*32,requestFingerprint=request_fp,
        recordedRequestFingerprint=recorded_fp,consumerStageFingerprint='f'*64,frame=frame,
        committedTokens=prompt_count,vocabularySize=256,tokenOrdinal=0,selectionPolicy=SELECTION,tokenID=7,
        logitsShape=[1,256],logitsDType='bfloat16',selectionDType='uint32',allLogitsFinite=True)
    if profiled:
        token.update(profile=PROFILE,profileFingerprint=profile_fp,
            finalBoundaryEnvelopeFingerprint=boundary['fingerprint'],finalBoundaryWireBytesSHA256=boundary['wireBytesSHA256'])
    else:token['finalBoundaryEnvelopeSHA256']=boundary['wireBytesSHA256']
    token=vector(token,DOMAINS['token'] if profiled else None)
    acks={}
    for phase in ('ready','received','consumed'):
        parts=[DOMAINS['ack'] if profiled else 'qwen-stage-ack-v3',descriptor['flow'],agreement_fp,phase,boundary['fingerprint']]
        if profiled:parts.append(boundary['wireBytesSHA256'])
        acks[phase]=sha('|'.join(parts))
    parts=[DOMAINS['post_stop'] if profiled else 'qwen-prefill-post-stop-v1',descriptor['flow'],agreement_fp,'post_stop_release',token['fingerprint']]
    if profiled:parts.append(token['wireBytesSHA256'])
    result=dict(requestFingerprint=request_fp,recordedRequestFingerprint=recorded_fp,agreementFingerprint=agreement_fp,
        agreement=descriptor,inner=vector(inner),start=start,boundary=boundary,token=token,ackHex=acks,postStopHex=sha('|'.join(parts)))
    if profiled:result.update(profileFingerprint=profile_fp,profileMaterial=profile_material)
    else:result['lookahead']=vector(dict(version=2,flow='prompt_lookahead_one_v1',boundary=inner))
    return result


def swift_check(vectors):
    new, old = vectors['profiled'], vectors['legacy']
    checks=[f'fixture.agreement.request.request.profile.fingerprint == "{new["profileFingerprint"]}"',
        f'fixture.agreement.request.request.fingerprint == "{new["requestFingerprint"]}"',
        f'fixture.agreement.request.fingerprint == "{new["recordedRequestFingerprint"]}"',
        f'fixture.agreement.fingerprint == "{new["agreementFingerprint"]}"',
        f'sha256(try fixture.final.boundary.encoded()) == "{new["inner"]["wireBytesSHA256"]}"']
    for name,expr in [('start','fixture.start'),('boundary','fixture.final'),('token','fixture.token')]:
        checks += [f'{expr}.wireBytesSHA256 == "{new[name]["wireBytesSHA256"]}"',f'{expr}.fingerprint == "{new[name]["fingerprint"]}"']
    for phase in ('ready', 'received', 'consumed'):
        value = new['ackHex'][phase]
        checks.append(f'QwenLayerStageProfiledPrefillBoundaryAcknowledgement.values(envelope: fixture.final, phase: .{phase}) == Array("{value}".utf8).map(Int32.init)')
    checks.append(f'QwenLayerStageProfiledPrefillPostStopAcknowledgement.values(token: fixture.token) == Array("{new["postStopHex"]}".utf8).map(Int32.init)')
    legacy_checks=[f'sha256(try legacy.final.boundary.encoded()) == "{old["inner"]["wireBytesSHA256"]}"',
        f'sha256(lookahead.encoded()) == "{old["lookahead"]["wireBytesSHA256"]}"',
        f'sha256(legacy.start.encoded()) == "{old["start"]["wireBytesSHA256"]}"',
        f'sha256(legacy.final.encoded()) == "{old["boundary"]["wireBytesSHA256"]}"',
        f'sha256(legacy.token.encoded()) == "{old["token"]["wireBytesSHA256"]}"']
    return '\n'.join(['import Foundation','','// Generated from the independent Python canonical-JSON/domain recipe; no native output.',
        'func checkQwenLayerStageProfiledWireGolden(fixture: QwenLayerStageProfiledWireCheckFixture) throws {',
        '    guard '+',\n          '.join(checks)+' else {',
        '        throw ProbeError("Profiled wire differs from independently derived raw/domain/ACK golden vectors")','    }',
        '    let legacy = try QwenLayerStagePrefillWireCheckFixture()',
        '    let expected = try legacy.agreement.boundaryExpectation(for: legacy.final.boundary.frame)',
        '    let lookahead = try QwenLayerStageLookaheadWireEnvelope(boundary: legacy.final.boundary, expected: expected)',
        '    guard '+',\n          '.join(legacy_checks)+' else {',
        '        throw ProbeError("Existing v1/v2/v3 fixture bytes changed while adding the new profiled namespace")','    }','}',''])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    value=dict(kind='profiled_wire_source_derived_vectors',schemaVersion=1,cpuOnly=True,nativeExecutionPerformed=False,
               domains=DOMAINS,profiled=make(True),legacy=make(False))
    for name,data in [('wire-vectors-20260914.json',(json.dumps(value,indent=2,sort_keys=True)+'\n').encode()),
                      ('QwenLayerStageProfiledWireGoldenCheck.swift',swift_check(value).encode())]:
        with (args.output/name).open('xb') as stream:stream.write(data)
    print(json.dumps({name:{'bytes':value['profiled'][name]['byteCount'],'sha256':value['profiled'][name]['wireBytesSHA256'],
        'fingerprint':value['profiled'][name]['fingerprint']} for name in ('start','boundary','token')},sort_keys=True))


if __name__=='__main__':main()
