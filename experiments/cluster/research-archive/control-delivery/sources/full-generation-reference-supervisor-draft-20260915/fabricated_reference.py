"""Fabricated DTOs and Python pipe child; no model, Metal or remote work."""
import json
import os
from pathlib import Path
import sys
import time

from reference_contract import digest, expected_identity
from reference_inputs import ARTIFACT, CONFIGURATION, MANIFEST


def records(job, tokens, pid):
    identity = expected_identity(job, tokens)
    plan = 'c'*64
    first = dict(identity, kind='qwen_full_generation_reference_admitted', schemaVersion=1,
        verifiedModelLoaded=False, freshRequestStateCreated=False, correctnessOnly=True,
        throughputMeasurementValid=False, manifestSHA256=MANIFEST,
        artifactSHA256=ARTIFACT, configurationSHA256=CONFIGURATION, planSHA256=plan)
    selected = [0]*128
    execution = dict(identity, schema='qwen_full_generation_reference_v1',
        source=dict(artifactAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIGURATION,
            sourceParameterLayoutSHA256='d'*64, planSHA256=plan, arithmeticEnvironmentSHA256='e'*64,
            bf16ConversionEnabled=True, embeddingActivationDType='bfloat16', sourceModelTensorBytes=5038041600,
            layerCount=32, vocabularySize=248320),
        sourceLoad=dict(configurationSHA256=CONFIGURATION, verifiedAggregateSHA256=ARTIFACT,
            tensorCount=927, sourceTensorCount=927, loadedTensorBytes=5038041600, sourceModelTensorBytes=5038041600),
        promptCount=8192, chunkSize=512, requirements=dict(requestFingerprint=identity['requestFingerprint'], maximumTokens=8320),
        selectedTokenIDs=selected, selectedTokenIDsSHA256=digest(','.join(map(str, selected))),
        finishReason='length', completedFrames=143, committedTokens=8319,
        tokens=[dict(outputOrdinal=i, committedTokens=8192+i, tokenID=0) for i in range(128)],
        finalLogits=dict(shape=[1,248320], dtype='bfloat16', byteCount=496640,
            logicalBytesSHA256='f'*64, values=[0]*248320),
        finalState=dict(committedTokens=8319, entries=[{}]*72, fingerprint='a'*64), timing=dict(fabricated=True),
        finalStateCaptures=1, allRequestStateRetired=True, modelRemainsResident=True,
        fullVocabularyValuesRetainedForEveryToken=False, mtpEnabled=False, correctnessOnly=True,
        candidateNumericalComparisonPerformed=False, physicalTransferQualified=False)
    final = dict(kind='qwen_full_generation_reference_report', schemaVersion=1, completed=True,
        modelReleased=True, allRequestStateRetired=True, verifiedFullModelLoads=1, freshFullModelRequests=1,
        correctnessOnly=True, throughputMeasurementValid=False, physicalTransferQualified=False,
        candidateNumericalComparisonPerformed=False, execution=execution,
        resources=dict(policy='qwen_full_generation_reference_resources_v1',
            budget=dict(requestFingerprint=identity['requestFingerprint'], planFingerprint=plan),
            authorizedTensorCount=927, observationCount=100, minimumActualFreeBytes=8*1024**3,
            maximumObservedActiveBytes=6*1024**3, requestResourceAdmissionPerformed=True,
            actualAllocatorBoundsUsed=True, reclaimableUsedForAdmission=False, wholeProcessPeakBoundEstablished=False),
        memory=[{},{}], runtime=dict(processID=pid, mainBundlePath=job['deployment'],
            binaryOrBundleHashVerifiedByNative=False, providerEligibilityEstablished=False,
            recommendedWorkingSetUsedForAdmission=False))
    return first, final


def main():
    case, jobfile = sys.argv[1:]
    job = json.loads(Path(jobfile).read_text())
    first, final = records(job, [17]*8192, os.getpid())
    def emit(value, lf=True):
        sys.stdout.buffer.write(json.dumps(value, separators=(',',':')).encode() + (b'\n' if lf else b''))
        sys.stdout.buffer.flush()
    if case == 'report-first':
        emit(final); return
    if case == 'malformed':
        sys.stdout.buffer.write(b'{broken}\n'); return
    if case == 'wrong-request':
        first['requestID'] = '00000000-0000-0000-0000-000000000099'
    if case == 'stderr':
        sys.stderr.write('fabricated native error\n'); sys.stderr.flush(); return
    emit(first)
    if case == 'incomplete':
        return
    if case == 'timeout':
        time.sleep(10); return
    if case == 'failed-report':
        final['completed'] = False
    if case == 'short-row':
        final['execution']['finalLogits']['values'].pop()
    if case == 'wrong-pid':
        final['runtime']['processID'] += 1
    emit(final, lf=case != 'truncated')
    if case == 'extra':
        emit(first)
    if case == 'nonzero':
        raise SystemExit(7)


if __name__ == '__main__':
    main()
