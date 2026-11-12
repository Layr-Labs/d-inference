"""Prospective CPU adapter for a source-generated 8K solo diagnostic result.

The complete frozen reference row is reconstructed; candidate values are absent.
No native reference assertion or full native-byte equality is inferred.
"""
import copy
import importlib.util
import json
import math
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parent.parent
BASELINE_SHA='da85eb1e79a43c16575e6a8ffd48594ccb72306c16543a1e02c24903b89c154a'
BASELINE_RECEIPT='runs/qwen-long-prefill-reference-peer24-20260914/independent-cpu-audit-receipt.json'
BASELINE_RECEIPT_SHA='bff08ef62a84c2ebd950ef692989abe6c037773cb1cc2af50bf5a31acc63c14c'
PINNED={
 'long-prefill-reference-audit-draft/qwen_long_prefill_reference_audit.py':'e316c559f2827c539bd25f0c6baed226e21bc704df3e4facf0d889605914abd1',
 'long-prefill-solo-draft-rev2/source-manifest-20260914.json':'16bcf42c143ffbacb11c89bddc1acbb9a3a69eae6644cfd2e20a3291ffe53f58',
 'prefill-solo-timer-draft/QwenLayerStageSoloPrefillResult.swift':'3cce3c0e48db4078fda3b97c20bf74cf9cf142e3cc6d0d959279797a65b523f2',
 'prefill-solo-timer-draft/QwenLayerStageSoloPrefillReference.swift':'c2d65c183928a5b0ed8c1fbc43801f6ff0d2e241b80eb04f43caf254748708e8',
}
MAX_STDOUT=16*1024**2
MEMORY_PHASES=['before_full_model_load','full_model_loaded_no_request_state',
    'full_request_retired_weights_resident','full_model_released_cache_cleared']
_A=None


def context():
    global _A
    if _A is None:
        import hashlib
        name='long-prefill-reference-audit-draft/qwen_long_prefill_reference_audit.py'
        raw=(ROOT/name).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=PINNED[name]:raise ValueError('Frozen reference helper pin changed')
        spec=importlib.util.spec_from_file_location('long_solo_pinned_reference',ROOT/name)
        _A=importlib.util.module_from_spec(spec);spec.loader.exec_module(_A);_A.context()
    return _A


def verify_pins():
    a=context();pins={}
    for name,wanted in PINNED.items():
        raw=a.read_bounded(ROOT/name,2*1024**2)
        a.require(a.sha(raw)==wanted,'Frozen solo dependency changed: '+name)
        pins[name]=dict(sha256=wanted,byteCount=len(raw))
    manifest=json.loads((ROOT/'long-prefill-solo-draft-rev2/source-manifest-20260914.json').read_bytes())
    for item in manifest['files']:
        raw=a.read_bounded(item['path'],2*1024**2)
        a.require(a.sha(raw)==item['sha256'] and len(raw)==item['byteCount'],'Frozen solo source member changed')
    return pins


def parse_rows(raw):
    a=context();a.require(type(raw) is bytes and 0<len(raw)<=MAX_STDOUT,'Solo stdout exceeds bounds')
    lines=raw.splitlines();a.require(len(lines)==2 and all(lines),'Exactly ready and completed solo report required')
    rows=[]
    for line in lines:
        a.check_depth(line);row=a.context()['base'].parse_json(line.decode('utf8'))
        a.require(type(row) is dict,'Solo record must be an object');rows.append(row)
    return rows


def check_timing(value):
    a=context();a.require(type(value) is dict,'Solo diagnostic timing missing')
    flags=dict(includesFreshRequestState=True,includesFiniteArgmaxAndScalarReadback=True,
        includesBoundedCommitMetadata=True,includesTransport=False,excludesLoadReadinessFinalCaptureAndRetirement=True)
    numbers={'startUptimeNanoseconds','stopUptimeNanoseconds','elapsedNanoseconds',
        'promptTokensPerFirstTokenSecond','postStopThroughRequestCloseNanoseconds'}
    a.require(set(value)==set(flags)|numbers,'Solo timing schema differs')
    for key,wanted in flags.items():a.exact(value[key],wanted,'timing.'+key)
    start=a.integer(value['startUptimeNanoseconds'],0,2**64-1);stop=a.integer(value['stopUptimeNanoseconds'],0,2**64-1)
    elapsed=a.integer(value['elapsedNanoseconds'],1,2**64-1);post=a.integer(value['postStopThroughRequestCloseNanoseconds'],0,2**64-1)
    a.require(stop>start and stop-start==elapsed and stop+post<=2**64-1,'Solo UInt64 interval differs')
    rate=value['promptTokensPerFirstTokenSecond'];wanted=8192e9/float(elapsed)
    a.require(type(rate) in (int,float) and math.isfinite(rate) and rate>0 and rate==wanted,'Solo exact diagnostic rate differs')
    return dict(elapsedNanoseconds=elapsed,promptTokensPerFirstTokenSecond=rate,
        postStopThroughRequestCloseNanoseconds=post,diagnosticOnly=True,
        scope='Source-placed fresh request construction through finite argmax/scalar readback; no per-phase profiler timestamps.')


def check_memory(rows):
    a=context();a.require(type(rows) is list and len(rows)==4,'Four solo allocator observations required')
    previous=0
    for row,phase in zip(rows,MEMORY_PHASES):
        a.require(type(row) is dict and set(row)=={'phase','activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart'},
            'Solo memory schema differs')
        a.exact(row['phase'],phase,'memory phase');active=a.integer(row['activeMLXBytes']);a.integer(row['cachedMLXBytes'])
        peak=a.integer(row['peakMLXBytesSinceProcessStart']);a.require(peak>=active and peak>=previous,'Solo allocator peak differs');previous=peak
    a.require(rows[-1]['cachedMLXBytes']==0,'Solo native cache-clear assertion differs')
    return copy.deepcopy(rows)


def check_solo(rows,baseline_rows,prompt_data,expected_prompt_sha256):
    a=context();c=a.context();baseline=a.validate_reports(baseline_rows,prompt_data,expected_prompt_sha256)
    a.require(type(rows) is list and len(rows)==2 and all(type(row) is dict for row in rows),'Two solo records required')
    ready,report=rows;x=report.get('execution');a.require(type(x) is dict,'Missing solo execution')
    actual_request=x.get('request');a.require(type(actual_request) is dict and type(actual_request.get('request')) is dict,'Missing solo request')
    rid=actual_request['request'].get('requestID');prompt=a.prompt_tokens(prompt_data,expected_prompt_sha256)
    simple,history=a.request_identity(rid,prompt)
    a.require(rid.lower()!=baseline_rows[1]['evidence']['execution']['request']['request']['requestID'].lower(),
        'Fresh solo request must differ from reference request')
    steps,commits=a.frames_and_commits(prompt)
    request=dict(request=dict(profile=a.PROFILE,requestID=rid,batchSize=1,promptCount=8192,chunkSize=512,outputCount=1),
        vocabularySize=248320,promptTokenIDs=prompt,teacherTokenIDs=[],steps=steps,fingerprint=history)
    a.exact(actual_request,request,'solo request')
    selection=dict(requestFingerprint=simple,recordedRequestFingerprint=history,frame=steps[-1]['frame'],committedTokens=8192,
        vocabularySize=248320,outputOrdinal=0,policy='mlx_argmax_all_axes_with_finite_guard_v1',tokenID=baseline['argmaxTokenID'],
        logitsShape=[1,248320],logitsDType='bfloat16',selectionDType='uint32',allLogitsFinite=True)
    wanted=dict(kind='qwen_long_prefill_solo_request',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=False,physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
        fullVocabularyValuesExported=False,nativeLogitBytesCompared=False,source=c['source'],sourceLoad=c['load'],request=request,
        commits=commits,selection=selection,finalState=baseline_rows[1]['evidence']['execution']['finalState'],
        finalLogits=baseline['finalLogits'],timing=x.get('timing'),completedFrames=16,committedTokens=8192,
        perFrameStateCaptures=0,perFrameLogitCaptures=0,finalStateCaptures=1,finalLogitCaptures=1,nativeTokenSelections=1,allRequestStateRetired=True)
    a.require(set(x)==set(wanted),'Solo execution schema differs')
    for key in wanted:
        if key not in ('request','timing'):a.exact(x[key],wanted[key],'solo execution.'+key)
    # Full-state equality above is to the independently checked reference.
    a.require(a.state_fingerprint(x['finalState']['entries'])==x['finalState']['fingerprint'],'Solo complete-state fingerprint differs')
    timing=check_timing(x['timing']);memory=check_memory(report.get('memory'))
    a.exact(ready,dict(kind='qwen_long_prefill_solo_ready',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        verifiedModelLoaded=True,freshRequestStateCreated=False,profile=a.PROFILE,profileFingerprint=baseline['profileFingerprint'],
        promptFileSHA256=expected_prompt_sha256,arithmeticEnvironmentSHA256=baseline['arithmeticEnvironmentSHA256'],
        recordedRequestFingerprint=history),'solo ready')
    terminal=dict(kind='qwen_long_prefill_solo_report',schemaVersion=1,completed=True,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=False,physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True,
        profile=a.PROFILE,profileFingerprint=baseline['profileFingerprint'],promptFileSHA256=expected_prompt_sha256,
        promptTokenIDsSHA256=baseline['promptTokenIDsSHA256'],arithmeticEnvironment=c['environment'],
        arithmeticEnvironmentSHA256=baseline['arithmeticEnvironmentSHA256'],resourceAdmission=c['resource'],execution=x,memory=memory)
    a.require(set(report)==set(terminal),'Solo terminal schema differs')
    for key in terminal:
        if key not in ('execution','memory'):a.exact(report[key],terminal[key],'solo terminal.'+key)
    return dict(status='passed',scope='registered9b_long_prefill_8192_chunk512_output1_solo',
        requestFingerprint=simple,recordedRequestFingerprint=history,requestID=rid,
        baselineReferenceFingerprint=baseline['referenceFingerprint'],baselineRequestFingerprint=baseline['requestFingerprint'],
        profileFingerprint=baseline['profileFingerprint'],promptFileSHA256=expected_prompt_sha256,
        promptTokenIDsSHA256=baseline['promptTokenIDsSHA256'],arithmeticEnvironmentSHA256=baseline['arithmeticEnvironmentSHA256'],
        sourceTensorCount=927,sourceModelTensorBytes=5038041600,completedFrames=16,committedTokens=8192,
        finalStateComponents=72,finalStateLogicalBytes=319946784,finalStateSHA256=baseline['finalStateSHA256'],
        independentlyReconstructedStateOffsets=8,opaqueNumericalStateComponents=64,
        baselineFinalLogits=baseline['finalLogits'],baselineReconstructedNativeLogitBytes=496640,
        candidateNativeBytesIndependentlyReconstructed=False,candidateFullVocabularyValuesExported=False,
        candidateLogitMetadataAndDigestExact=True,candidateStateMetadataAndDigestsExact=True,
        selectedTokenID=baseline['argmaxTokenID'],baselineMaximumLogit=baseline['maximumLogit'],baselineMaximumTieCount=baseline['maximumTieCount'],
        timing=timing,memory=memory,throughputQualified=False,physicalTransferQualified=False,independentModelForwardPerformed=False,
        limitations=[
            'The pinned full-model reference row is reconstructed as BF16 native bytes from exported Float values, including signed zero. Candidate logits export metadata and a digest only; there is no independently reconstructed candidate row or direct native-byte comparison.',
            'All72 final state entries and their union fingerprint match the reference. Only eight Int32 offset digests can be reconstructed;64 numerical-state digests remain opaque. No intermediate numerical state is exported.',
            'Source loading, native commits/selection, fresh ownership, retirement/model release and early arithmetic environment application remain source-bound native assertions requiring separate archive/executable/runtime provenance. The source-generated request UUID is checked for consistency and difference from the reference, not external cohort admission.',
            'Diagnostic timing is source-placed fresh CBv2 construction through finite argmax/scalar readback; final captures and close follow stop. Post-stop through request close excludes outer model release. No stable throughput, representative workload, physical transport or speedup is qualified.',
            'MLX observations are cumulative allocator values, not RSS or whole-process peaks. The admitted named-tensor budget is not a complete memory bound.'])


def validate(stdout_path,baseline_path,prompt_path,expected_prompt_sha256):
    a=context();before=verify_pins();reference_pins=a.verify_pins();self_before=Path(__file__).read_bytes()
    raw=a.read_bounded(stdout_path,MAX_STDOUT);baseline=a.read_bounded(baseline_path,MAX_STDOUT)
    prompt=a.read_bounded(prompt_path,a.MAX_PROMPT);receipt=a.read_bounded(ROOT/BASELINE_RECEIPT,65536)
    a.require(a.sha(baseline)==BASELINE_SHA and a.sha(receipt)==BASELINE_RECEIPT_SHA,'Frozen completed 8K reference qualification changed')
    result=check_solo(parse_rows(raw),a.parse_rows(baseline),prompt,expected_prompt_sha256)
    a.require(a.read_bounded(stdout_path,MAX_STDOUT)==raw and a.read_bounded(baseline_path,MAX_STDOUT)==baseline
        and a.read_bounded(prompt_path,a.MAX_PROMPT)==prompt and a.read_bounded(ROOT/BASELINE_RECEIPT,65536)==receipt,'Solo audit input changed')
    a.require(verify_pins()==before and a.verify_pins()==reference_pins and Path(__file__).read_bytes()==self_before,'Frozen solo audit dependency changed')
    result.update(stdoutSHA256=a.sha(raw),stdoutByteCount=len(raw),baselineStdoutSHA256=a.sha(baseline),
        baselineCPUReceiptSHA256=a.sha(receipt),promptByteCount=len(prompt),helperSHA256=a.sha(self_before),
        frozenDependencyPins=before,referenceDependencyPins=reference_pins,frozenInputsUnchanged=True)
    return result


if __name__=='__main__':
    if len(sys.argv)!=5:raise SystemExit('Usage: qwen_long_prefill_solo_audit.py STDOUT BASELINE PROMPT EXPECTED_PROMPT_SHA')
    print(json.dumps(validate(*sys.argv[1:]),indent=2,sort_keys=True,allow_nan=False))
