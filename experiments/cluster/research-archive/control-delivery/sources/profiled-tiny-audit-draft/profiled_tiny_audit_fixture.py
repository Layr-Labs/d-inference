"""Invented CPU fixture records for prospective validator tests, never native evidence."""
import copy
from profiled_tiny_expected import (DEFAULT_BINDINGS, ENVIRONMENT, PROFILE, canonical, configuration, frames,
    native_logit_bytes, prompt, recorded_fingerprint, sha, state_bytes)
from profiled_tiny_loader_audit import PROOF_FLAGS


def spec(identity, count):
    return dict(profile=PROFILE, requestID='00000000-0000-0000-0000-%012d' % identity,
                batchSize=1, promptCount=count, chunkSize=512, outputCount=1)


def loader(dtype):
    source_hash = sha(canonical(configuration(dtype))); source_bytes = 237 * 4
    common = dict(verifiedAggregateSHA256='a' * 64, sourceConfigurationSHA256=source_hash,
        planSHA256='b' * 64, sourceTensorManifestSHA256='c' * 64, sourceModelTensorBytes=source_bytes)
    commitment = dict(common, schemaVersion=1, bf16ConversionEnabled=True,
        largestSourceTensorBytes=4, sourceTensorCount=237, canonicalTensorCount=237, stages=[])
    receipts = []
    for index, count in enumerate((118, 119)):
        receipts.append(dict(common, schemaVersion=1, stageIndex=index,
            constructionConfigurationSHA256='d' * 64, stagePlanSHA256='e' * 64,
            sourceParameterLayoutSHA256='f' * 64, parameterLayoutSHA256='1' * 64,
            activeParameterLayoutSHA256='2' * 64, activeMappingSHA256='3' * 64,
            embeddingActivationDType=dtype, bf16ConversionEnabled=True, loadedTensorBytes=count * 4,
            activeTensors=[dict(sourceName='cpu.fixture.%d.%d' % (index, n), localName='cpu.%d' % n,
                shape=[1], sourceDType='uint32', loadedDType='uint32', byteCount=4) for n in range(count)],
            inertTensorBytes=4, storageCommitment=copy.deepcopy(commitment), storageCommitmentSHA256=sha(canonical(commitment))))
    result = dict(kind='qwen_layer_stage_loader_check', syntheticDType=dtype, wrapped=dtype == 'bfloat16',
        fp16LayerMetadata=False, fp16MetadataTensorCount=0, tensorChecks=237, tensorChecksAfterSourceDeletion=237,
        sourceTensorBytes=source_bytes, activeTensorBytes=[118 * 4, 119 * 4], inertTensorBytes=[4, 4],
        receipts=receipts, badAggregateRejectedStages=[0, 1], corruptedSourceRejectedStages=[0, 1], modelForwardCompared=False)
    result.update({key: True for key in PROOF_FLAGS})
    return result


def lifecycle(identity):
    return dict(kind='qwen_layer_stage_profiled_lifecycle_check', correctnessOnly=True, throughputMeasurementValid=False,
        request=spec(identity, 1025), faultInjectedAfterFirstStageCommit=True, failedStageFrontiers=[512, 0],
        bothRequestsFailedAndRetired=True, retiredRequestReuseRejected=2)


def parity(dtype, count, identity):
    request = spec(identity, count); tokens = prompt(count); timeline = frames(count)
    recorded = dict(request=request, vocabularySize=512, promptTokenIDs=tokens, teacherTokenIDs=[],
        fingerprint=recorded_fingerprint(request), steps=[dict(frame=f,
            tokenIDs=tokens[f['tokenOffset']:f['tokenOffset'] + f['tokenCount']],
            committedTokens=f['tokenOffset'] + f['tokenCount']) for f in timeline])
    values = [float(index % 32) / 16 for index in range(512)]; values[17] = 9.0
    compared = []
    for frame in timeline:
        frontier = frame['tokenOffset'] + frame['tokenCount']
        entry = dict(phase='prefill', committedTokens=frontier, stateEntriesCompared=18,
            stateBytesCompared=state_bytes(dtype, frontier), fullStateSHA256='4' * 64, stateShapesDTypesAndBytesExact=True)
        if frame['finalPromptChunk']:
            entry.update(logitsBytesExact=True, logits=dict(shape=[1, 512], dtype=dtype,
                logicalBytesSHA256=sha(native_logit_bytes(values, dtype)), values=values))
        compared.append(entry)
    return dict(kind='qwen_layer_stage_profiled_parity_check', correctnessOnly=True,
        throughputMeasurementValid=False, interprocessTransportUsed=False, syntheticDType=dtype,
        sourceConfigurationSHA256=sha(canonical(configuration(dtype))), artifactAggregateSHA256='a' * 64,
        planSHA256='b' * 64, request=recorded, frames=compared, baselineSelectedToken=17, stageSelectedToken=17,
        allRequestsRetired=True, sourceFilesDeletedBeforeForward=True, nativeBoundaryBytesCopied=True)


def records():
    environment = dict(kind='qwen_layer_stage_profiled_fixture_environment', correctnessOnly=True,
        arithmeticEnvironment=dict(contract='qwen_cbv2_query128_bf16_tf32_default_v1', requiredValues=ENVIRONMENT.copy(),
            requiredAbsentNames=['MLX_METAL_GPU_ARCH', 'MLX_SDPA_BLOCKS'], full512TokenChunkQueryBlocks=4,
            defaultBindings=DEFAULT_BINDINGS.copy(), actualProcessEnvironmentMustBePassedBeforeMLXInitialization=True,
            sourceBinaryMetalLibraryAndHardwareIdentityStillRequired=True, sameChunkFullModelReferenceStillRequired=True,
            doesNotValidateOtherTimingOrResourceEnvironment=True, numericalOrPerformanceQualificationEstablished=False),
        profile=PROFILE, promptCounts=[1025, 8192], chunkSize=512, outputCount=1,
        syntheticDTypes=['float32', 'bfloat16'], throughputMeasurementValid=False)
    rows = [environment]
    for index, dtype in enumerate(('float32', 'bfloat16')):
        rows.extend([loader(dtype), lifecycle(index * 3 + 1), parity(dtype, 1025, index * 3 + 2), parity(dtype, 8192, index * 3 + 3)])
    return rows
