"""Fabricated records only; generated IDs and opaque synthetic state hashes."""
import copy
import importlib.util
import json

import qwen_long_prefill_solo_audit as audit

FACTORY_SHA='f05a24ad2910c1194c7d14c0364ee98e45e89139961c308706971af4ad4b05f6'


def replace(value,mapping):
    if type(value) is str:return mapping.get(value,value)
    if type(value) is dict:return {k:replace(v,mapping) for k,v in value.items()}
    if type(value) is list:return [replace(v,mapping) for v in value]
    return value


def fixture():
    a=audit.context();path=audit.ROOT/'long-prefill-reference-audit-draft/reference_fixture.py'
    assert a.sha(path.read_bytes())==FACTORY_SHA
    spec=importlib.util.spec_from_file_location('long_solo_reference_fixture',path)
    factory=importlib.util.module_from_spec(spec);spec.loader.exec_module(factory)
    prompt=json.dumps([i%317 for i in range(8192)],separators=(',',':')).encode()
    baseline=factory.make_fixture(a,prompt);e=baseline[1]['evidence'];old=e['execution']
    rid='ABCDEF01-2345-6789-ABCD-EF0123456789';simple,history=a.request_identity(rid,old['request']['promptTokenIDs'])
    request=replace(old['request'],{old['request']['request']['requestID']:rid,old['request']['fingerprint']:history})
    selection={k:copy.deepcopy(v) for k,v in old['selection'].items()
        if k not in ('cpuCrosscheckPolicy','maximumTieCount','maximumLogit','nativeSelectionMatchesCapturedFullRow')}
    selection.update(requestFingerprint=simple,recordedRequestFingerprint=history)
    timing=dict(startUptimeNanoseconds=10_000_000_000,stopUptimeNanoseconds=12_000_000_000,elapsedNanoseconds=2_000_000_000,
        promptTokensPerFirstTokenSecond=4096.0,postStopThroughRequestCloseNanoseconds=50_000_000,
        includesFreshRequestState=True,includesFiniteArgmaxAndScalarReadback=True,includesBoundedCommitMetadata=True,
        includesTransport=False,excludesLoadReadinessFinalCaptureAndRetirement=True)
    x=dict(kind='qwen_long_prefill_solo_request',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=False,physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
        fullVocabularyValuesExported=False,nativeLogitBytesCompared=False,source=copy.deepcopy(old['source']),sourceLoad=copy.deepcopy(old['sourceLoad']),
        request=request,commits=copy.deepcopy(old['commits']),selection=selection,finalState=copy.deepcopy(old['finalState']),
        finalLogits={k:v for k,v in old['finalLogits'].items() if k!='values'},timing=timing,completedFrames=16,committedTokens=8192,
        perFrameStateCaptures=0,perFrameLogitCaptures=0,finalStateCaptures=1,finalLogitCaptures=1,nativeTokenSelections=1,allRequestStateRetired=True)
    ready=dict(kind='qwen_long_prefill_solo_ready',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        verifiedModelLoaded=True,freshRequestStateCreated=False,profile=a.PROFILE,profileFingerprint=e['profileFingerprint'],
        promptFileSHA256=e['promptFileSHA256'],arithmeticEnvironmentSHA256=e['arithmeticEnvironmentSHA256'],recordedRequestFingerprint=history)
    phases=['before_full_model_load','full_model_loaded_no_request_state','full_request_retired_weights_resident','full_model_released_cache_cleared']
    memory=[dict(phase=p,activeMLXBytes=100,cachedMLXBytes=0,peakMLXBytesSinceProcessStart=6_000_000_000) for p in phases]
    report=dict(kind='qwen_long_prefill_solo_report',schemaVersion=1,completed=True,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=False,physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True,
        profile=a.PROFILE,profileFingerprint=e['profileFingerprint'],promptFileSHA256=e['promptFileSHA256'],promptTokenIDsSHA256=e['promptTokenIDsSHA256'],
        arithmeticEnvironment=copy.deepcopy(e['arithmeticEnvironment']),arithmeticEnvironmentSHA256=e['arithmeticEnvironmentSHA256'],
        resourceAdmission=copy.deepcopy(e['resourceAdmission']),execution=x,memory=memory)
    return dict(rows=[ready,report],baseline=baseline,prompt=prompt,promptSHA=a.sha(prompt))


def encoded(rows):return b''.join(json.dumps(row,sort_keys=True,separators=(',',':'),allow_nan=False).encode()+b'\n' for row in rows)
