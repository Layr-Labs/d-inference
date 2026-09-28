#!/usr/bin/env python3
"""Post-load metadata inventory replay; no tensor values or native execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from stage_load_contract import bounded_regular, require, validate_result, MAX_STDOUT, PROFILES
from selected_expected import expected, exact, digest, FIXTURE

LOAD_KEYS = set('schemaVersion stageIndex verifiedAggregateSHA256 sourceConfigurationSHA256 constructionConfigurationSHA256 planSHA256 stagePlanSHA256 sourceTensorManifestSHA256 sourceParameterLayoutSHA256 parameterLayoutSHA256 activeParameterLayoutSHA256 activeMappingSHA256 embeddingActivationDType bf16ConversionEnabled sourceModelTensorBytes loadedTensorBytes largestHostTensorBytes activeTensors inertModules inertTensorBytes storageCommitment storageCommitmentSHA256'.split())
BUDGET_KEYS = set('model stageIndex profileFingerprint planFingerprint pairRequirementFingerprint selectedRequirementFingerprint activeMappingSHA256 active allocationBounds inertAllocationBound roundedResidentBytes largestHostTensorBytes resourceAdmissionPerformed forwardExecutionAuthorized'.split())
STORAGE_KEYS = set('schemaVersion verifiedAggregateSHA256 sourceConfigurationSHA256 planSHA256 sourceTensorManifestSHA256 sourceModelTensorBytes largestSourceTensorBytes sourceTensorCount canonicalTensorCount bf16ConversionEnabled stages'.split())


def audit_row(report, e, stage):
    helper = e['helper']; load = report['load']; budget = report['budget']; storage = load['storageCommitment']
    require(set(load) == LOAD_KEYS and set(budget) == BUDGET_KEYS and type(storage) is dict and set(storage) == STORAGE_KEYS,
            'Closed loaded inventory/storage/budget keys differ')
    exact(load['activeTensors'], e['active'][stage], 'load.activeTensors')
    exact(load['inertModules'], e['inert'][stage], 'load.inertModules')
    exact(budget['active'], e['active'][stage], 'budget.active')
    require(type(storage['stages']) is list and len(storage['stages']) == 2, 'Storage must retain both source partitions')
    for i, actual in enumerate(storage['stages']):
        require(type(actual) is dict, 'Storage stage summary is absent')
        wanted = dict(e['summaries'][i], constructionConfigurationSHA256=digest(actual.get('constructionConfigurationSHA256'),'construction'),
                      stagePlanSHA256=digest(actual.get('stagePlanSHA256'),'stage Plan'))
        exact(actual, wanted, 'storage.stages['+str(i)+']')
    digest(load['planSHA256'], 'Plan'); digest(load['sourceTensorManifestSHA256'], 'source offsets manifest')
    wanted_storage = dict(schemaVersion=1, verifiedAggregateSHA256=e['artifactSHA256'],
        sourceConfigurationSHA256=e['configurationSHA256'], planSHA256=load['planSHA256'],
        sourceTensorManifestSHA256=load['sourceTensorManifestSHA256'], sourceModelTensorBytes=e['sourceBytes'],
        largestSourceTensorBytes=e['largestSourceBytes'], sourceTensorCount=len(e['source']), canonicalTensorCount=len(e['source']),
        bf16ConversionEnabled=True, stages=storage['stages'])
    exact(storage, wanted_storage, 'storageCommitment')
    exact(load['storageCommitmentSHA256'], helper.sha(helper.canonical(storage)), 'storageCommitmentSHA256')
    summary = storage['stages'][stage]
    for key in ('constructionConfigurationSHA256','stagePlanSHA256','activeMappingSHA256',
                'activeParameterLayoutSHA256','parameterLayoutSHA256','loadedTensorBytes','inertTensorBytes'):
        exact(load[key], summary[key], 'load.'+key)
    exact(load['sourceParameterLayoutSHA256'], e['sourceLayoutSHA256'], 'sourceParameterLayoutSHA256')
    exact(load['sourceModelTensorBytes'], e['sourceBytes'], 'sourceModelTensorBytes')
    exact(load['largestHostTensorBytes'], max(r['byteCount'] for r in e['active'][stage]), 'largestHostTensorBytes')
    exact(load['embeddingActivationDType'], 'bfloat16', 'embeddingActivationDType')
    exact(budget['activeMappingSHA256'], summary['activeMappingSHA256'], 'budget.activeMappingSHA256')
    exact(budget['largestHostTensorBytes'], load['largestHostTensorBytes'], 'budget.largestHostTensorBytes')
    bounds = budget['allocationBounds']
    require(type(bounds) is list and len(bounds) == len(e['active'][stage]), 'Allocator bound count differs')
    require(all(type(b) is int and b >= r['byteCount'] for b,r in zip(bounds,e['active'][stage])), 'Allocator bound below canonical bytes')
    inert = budget['inertAllocationBound']
    require(type(inert) is int and inert >= summary['inertTensorBytes'], 'Inert allocation bound below logical bytes')
    exact(budget['roundedResidentBytes'], sum(bounds)+inert, 'budget.roundedResidentBytes')
    for key in ('pairRequirementFingerprint','selectedRequirementFingerprint'):
        digest(budget[key], key)
    arithmetic = report['arithmeticEnvironment']
    require(type(arithmetic) is dict, 'Arithmetic environment receipt missing')
    exact(arithmetic, dict(contract='qwen_cbv2_query128_bf16_tf32_default_v1',
        requiredValues={'DARKBLOOM_BF16_WEIGHTS':'1','DARKBLOOM_CBV2_ATTN_QUERY_BLOCK':'128','MLX_ENABLE_TF32':'1'},
        requiredAbsentNames=['MLX_METAL_GPU_ARCH','MLX_SDPA_BLOCKS'], full512TokenChunkQueryBlocks=4,
        defaultBindings={
            'MLX_METAL_GPU_ARCH':'detect actual Metal device architecture; no override',
            'MLX_SDPA_BLOCKS':'source default 0; native adaptive block selection',
            'MLX_ENABLE_TF32':'explicit 1 matches pinned source default; permits eligible NAX paths',
            'DARKBLOOM_BF16_WEIGHTS':'explicit 1 converts stored Float16 tensors to BFloat16 before subsequent arithmetic',
            'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK':'explicit 128 matches pinned source default; chunk512 uses four query blocks'},
        actualProcessEnvironmentMustBePassedBeforeMLXInitialization=True,
        sourceBinaryMetalLibraryAndHardwareIdentityStillRequired=True,
        sameChunkFullModelReferenceStillRequired=True,
        doesNotValidateOtherTimingOrResourceEnvironment=True,
        numericalOrPerformanceQualificationEstablished=False), 'arithmeticEnvironment')
    counts = {dtype:sum(r['loadedDType']==dtype for r in e['active'][stage])
              for dtype in sorted({r['loadedDType'] for r in e['active'][stage]})}
    return dict(passed=True, model=e['profile'], stageIndex=stage, sourceTensorCount=len(e['source']),
        sourceTensorBytes=e['sourceBytes'], selectedActiveTensorCount=len(e['active'][stage]),
        selectedLoadedTensorBytes=summary['loadedTensorBytes'], selectedLoadedDTypeCounts=counts,
        selectedInertTensorCount=summary['inertTensorCount'], selectedInertLogicalBytes=summary['inertTensorBytes'],
        defaultHalfOwnershipAndLocalMappingReplayed=True, selectedLoadedMetadataMatchesRegisteredSource=True,
        selectedAndFullExpectedLayoutDigestsReplayed=True, activeMappingAndStorageCommitmentDigestsReplayed=True,
        exactInertMetadataSentinelsMatched=True, otherStageSummaryIsExpectedMetadataOnly=True,
        inertValuesOrEvaluationIndependentlyVerified=False,
        allocationBoundsOnlyArithmeticChecked=True, allocatorFootprintIndependentlyReplayed=False,
        planAndProfileSerializationIndependentlyReplayed=False, sourceOffsetManifestIndependentlyReplayed=False,
        resourceSamplesIndependentlyAudited=False, nativeLifetimeIndependentlyObserved=False,
        tensorValuesReadOrCompared=False, numericalParityEstablished=False, throughputMeasurementValid=False)


def validate(stdout_path, expected_stdout_sha256, profile, stage_index, fixture_path=FIXTURE):
    require(profile in PROFILES and type(stage_index) is int and stage_index in (0,1), 'Invalid expected profile/stage')
    digest(expected_stdout_sha256, 'explicit stdout pin')
    raw = bounded_regular(stdout_path, MAX_STDOUT)
    require(hashlib.sha256(raw).hexdigest() == expected_stdout_sha256, 'Complete stdout raw pin differs')
    validate_result(raw, profile, stage_index)
    e = expected(profile, fixture_path)
    report = e['helper'].decode(raw)
    result = audit_row(report, e, stage_index)
    result.update(kind='selected_stage_loaded_metadata_audit', schemaVersion=1,
                  stdoutSHA256=expected_stdout_sha256, stdoutBytes=len(raw), retainedMetadataSHA256=e['helper'].FIXTURE_SHA)
    return result


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--stdout', type=Path, required=True)
    parser.add_argument('--stdout-sha256', required=True)
    parser.add_argument('--profile', choices=PROFILES, required=True)
    parser.add_argument('--stage-index', choices=('0','1'), required=True)
    parser.add_argument('--retained-metadata', type=Path, default=FIXTURE)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(arguments)
    require(args.output.parent.is_dir() and not os.path.lexists(args.output), 'Audit output must be a new file')
    try:
        result = validate(args.stdout,args.stdout_sha256,args.profile,int(args.stage_index),args.retained_metadata)
    except Exception as error:
        result = dict(kind='selected_stage_loaded_metadata_audit',schemaVersion=1,passed=False,
            expectedStdoutSHA256=args.stdout_sha256,expectedProfile=args.profile,expectedStageIndex=int(args.stage_index),
            error=type(error).__name__+': '+str(error),tensorValuesReadOrCompared=False,
            numericalParityEstablished=False,throughputMeasurementValid=False)
    fd = os.open(args.output, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
    with os.fdopen(fd,'w') as stream: json.dump(result,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(dict(passed=result['passed'],receipt=str(args.output))))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
