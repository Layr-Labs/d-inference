"""Fabricated DTOs and Python pipe child; no model, Metal or remote work."""
import json
import os
from pathlib import Path
import sys
import time

from reference_contract import digest, expected_identity
from reference_state import expected_entries, fingerprint


def records(job, tokens, pid, actual_count=None, finish_reason="length"):
    identity = expected_identity(job, tokens)
    model = identity.model
    count = job['output_count'] if actual_count is None else actual_count
    frontier = len(tokens) + count - 1
    prefill = (len(tokens) - 1) // job['chunk_size'] + 1
    state_entries = [dict(x, sha256='a'*64) for x in expected_entries(model, frontier)]
    evidence = []
    for index in range(count):
        offset = (prefill-1)*job['chunk_size'] if index == 0 else len(tokens)+index-1
        evidence.append(dict(outputOrdinal=index, committedTokens=len(tokens)+index, tokenID=0,
            frame=dict(sequence=prefill+index-1, phase='prefill' if index == 0 else 'decode',
                tokenOffset=offset, tokenCount=len(tokens)-offset if index == 0 else 1, finalPromptChunk=index==0),
            maximumTieCount=248320, maximumLogit=0, logitsShape=[1,248320], logitsDType='bfloat16',
            logitsByteCount=496640, logitsLogicalBytesSHA256='f'*64,
            policy='mlx_argmax_all_axes_with_finite_guard_v1',
            cpuCrosscheckPolicy='finite_maximum_lowest_vocabulary_index_v1', nativeSelectionMatchesCapturedFullRow=True))
    plan = 'c'*64
    first = dict(identity, kind='qwen_full_generation_reference_admitted', schemaVersion=1,
        verifiedModelLoaded=False, freshRequestStateCreated=False, correctnessOnly=True,
        throughputMeasurementValid=False, manifestSHA256=model.manifest,
        artifactSHA256=model.artifact, configurationSHA256=model.configuration, planSHA256=plan)
    selected = [0]*count
    if finish_reason == 'eos':
        selected[-1] = job['stop_token_ids'][0]
        evidence[-1]['tokenID'] = selected[-1]
    execution = dict(identity, schema='qwen_full_generation_reference_v1',
        source=dict(artifactAggregateSHA256=model.artifact, sourceConfigurationSHA256=model.configuration,
            sourceParameterLayoutSHA256='d'*64, planSHA256=plan, arithmeticEnvironmentSHA256='e'*64,
            bf16ConversionEnabled=True, embeddingActivationDType='bfloat16', sourceModelTensorBytes=model.source_bytes,
            layerCount=model.layers, vocabularySize=248320),
        sourceLoad=dict(configurationSHA256=model.configuration, verifiedAggregateSHA256=model.artifact,
            tensorCount=model.tensor_count, sourceTensorCount=model.tensor_count, loadedTensorBytes=model.source_bytes, sourceModelTensorBytes=model.source_bytes),
        promptCount=len(tokens), chunkSize=job["chunk_size"], requirements=dict(requestFingerprint=identity['requestFingerprint'], maximumTokens=identity["maximumTokens"]),
        selectedTokenIDs=selected, selectedTokenIDsSHA256=digest(','.join(map(str, selected))),
        finishReason=finish_reason, completedFrames=prefill+count-1, committedTokens=frontier,
        tokens=evidence,
        finalLogits=dict(shape=[1,248320], dtype='bfloat16', byteCount=496640,
            logicalBytesSHA256='f'*64, values=[0]*248320),
        finalState=dict(committedTokens=frontier, entries=state_entries, logicalByteCount=sum(x['byteCount'] for x in state_entries), fingerprint=fingerprint(frontier, state_entries)), timing=dict(fabricated=True),
        finalStateCaptures=1, allRequestStateRetired=True, modelRemainsResident=True,
        fullVocabularyValuesRetainedForEveryToken=False, mtpEnabled=False, correctnessOnly=True,
        candidateNumericalComparisonPerformed=False, physicalTransferQualified=False)
    final = dict(kind='qwen_full_generation_reference_report', schemaVersion=1, completed=True,
        modelReleased=True, allRequestStateRetired=True, verifiedFullModelLoads=1, freshFullModelRequests=1,
        correctnessOnly=True, throughputMeasurementValid=False, physicalTransferQualified=False,
        candidateNumericalComparisonPerformed=False, execution=execution,
        resources=dict(policy='qwen_full_generation_reference_resources_v1',
            budget=dict(requestFingerprint=identity['requestFingerprint'], planFingerprint=plan),
            authorizedTensorCount=model.tensor_count, observationCount=100, minimumActualFreeBytes=8*1024**3,
            maximumObservedActiveBytes=6*1024**3, requestResourceAdmissionPerformed=True,
            actualAllocatorBoundsUsed=True, reclaimableUsedForAdmission=False, wholeProcessPeakBoundEstablished=False),
        memory=[{},{}], runtime=dict(processID=pid, mainBundlePath=job['deployment'],
            binaryOrBundleHashVerifiedByNative=False, providerEligibilityEstablished=False,
            recommendedWorkingSetUsedForAdmission=False))
    return first, final


def main():
    case, jobfile = sys.argv[1:]
    job = json.loads(Path(jobfile).read_text())
    first, final = records(job, [17]*job['prompt_count'], os.getpid(),
        actual_count=2 if case == 'early-eos' else None, finish_reason='eos' if case == 'early-eos' else 'length')
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
