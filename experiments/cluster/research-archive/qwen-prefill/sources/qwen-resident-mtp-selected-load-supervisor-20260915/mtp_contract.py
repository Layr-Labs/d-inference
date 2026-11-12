"""Exact target/additional metadata and retirement gate, never a value oracle."""
import hashlib
from pathlib import Path

from binding_common import canonical, fields, integer, parse, require, same
from mtp_inputs import ARTIFACT, CONFIGURATION, COORDINATOR, MANIFEST, NATIVE
from mtp_observations import memory, os_observation, runtime
from selected_read_accounting import validated_load

SCHEMA = 'qwen_resident_mtp_selected_load_check_v1'


def expected_identity(job, deadline, control):
    matrix = hashlib.sha256(control['devicesRaw']).hexdigest()
    common = dict(schema='qwen_resident_jaccl_configuration_v1', backend='jaccl', topology='mesh',
                  worldSize='2', deviceMatrixSHA256=matrix, coordinator=COORDINATOR)
    return dict(schema=SCHEMA, type='admitted', identity=dict(membershipEpoch=job['run_id'],
        modelID='registered_qwen35_9b', artifactSHA256=ARTIFACT, configurationSHA256=CONFIGURATION,
        peers=[dict(id='load-check-peer%d'%rank, buildSHA256=NATIVE) for rank in (0, 1)]),
        rank=1, stageCut=4, deadlineUptimeNanoseconds=deadline, manifestSHA256=MANIFEST,
        planSHA256=control['target']['planSHA256'], arithmetic=control['arithmetic'],
        arithmeticSHA256=hashlib.sha256(canonical(control['arithmetic'])).hexdigest(),
        jacclConfiguration=dict(backend='jaccl', topology='mesh', worldSize=2, configuredRank=1,
            deviceMatrixPath=str(Path(job['run_dir'])/'devices.json'), deviceMatrixSHA256=matrix,
            coordinator=COORDINATOR, localDevice='rdma_en1', configurationFingerprint=hashlib.sha256(canonical(common)).hexdigest(),
            physicalDeviceIdentityVerified=False, physicalTransferQualified=False),
        allocatorPolicy='disable_freed_buffer_cache_v1', collectiveInitialized=False,
        bilateralAdmissionPerformed=False, selectedPayloadMaterialized=False, generationEnabled=False)


def admitted(raw, expected):
    require(0 < len(raw) <= 8*1024**2, 'Admitted record exceeds native cap')
    value = parse(raw)
    fields(value, ' '.join(expected)+' initialResources', 'admitted')
    same({k:v for k,v in value.items() if k != 'initialResources'}, expected, 'Actual admission')
    os_observation(value['initialResources'], expected['deadlineUptimeNanoseconds'])
    return value


def mtp_load(value, target, control):
    fields(value, 'placement targetLoadReceiptSHA256 loadedTensorBytes allocatorReservedTensorBytes '
           'sourceReadAccounting independentlyOwnedAdditionalBuffers sharesTargetFinalNormAndOutputHead '
           'targetResidualEmbeddingUnchanged generationEnabled requestHistoryAllocated', 'MTP load')
    tensors = control['additional']
    head = sorted((v for v in tensors if v['name'].startswith('mtp.')), key=lambda v:v['name'])
    embedding = sorted((v for v in tensors if not v['name'].startswith('mtp.')), key=lambda v:v['name'])
    require(len(head) == 31 and len(embedding) == 3, 'Frozen additional inventory differs')
    expected = dict(targetPlanSHA256=control['target']['planSHA256'], ownerRank=1,
        embeddingSourceOwnerRank=0, embeddingIsExplicitReplica=True, generationEnabled=False,
        head=head, embedding=embedding, headBytes=136881152, replicatedEmbeddingBytes=572129280,
        additionalTensorBytes=709010432)
    same(value['placement'], expected, 'Exact34 additional tensor placement')
    same(value['loadedTensorBytes'], 709010432, 'Additional selected bytes')
    integer(value['allocatorReservedTensorBytes'], 'Additional rounded tensor reserve', 709010432, 48*1024**3)
    same(value['targetLoadReceiptSHA256'], hashlib.sha256(canonical(target)).hexdigest(), 'Complete target receipt hash')
    for key in ('independentlyOwnedAdditionalBuffers', 'sharesTargetFinalNormAndOutputHead', 'targetResidualEmbeddingUnchanged'):
        same(value[key], True, key)
    same(value['generationEnabled'], False, 'MTP generation')
    same(value['requestHistoryAllocated'], False, 'MTP history')
    # Reuse the exact aligned-IO validator for34 whole selected spans. Metadata
    # identity above is independent; this proxy only adapts its counter API.
    io_expected = dict(activeTensors=tensors, loadedTensorBytes=709010432)
    validated_load(dict(io_expected, selectedPayloadReadAccounting=value['sourceReadAccounting']), io_expected)


def report(raw, expected, first, control, pid, deployment):
    require(0 < len(raw) <= 8*1024**2, 'Report exceeds native cap')
    value = fields(parse(raw), 'schema type completed admission payload initialMemory releasedMemory '
        'releasedResources runtime targetOwnerReleased assistantOwnerReleased verifiedFileOwnerReleased '
        'cacheClearCompleted targetLoadReceiptPreserved additionalBuffersCheckedAtMaterialization '
        'collectiveInitialized bilateralAdmissionPerformed forwardExecuted requestStateCreated generationEnabled '
        'tensorValuesIndependentlyCompared numericalParityEstablished pairwiseBufferAddressesIndependentlyCompared '
        'providerEligibilityEstablished throughputMeasurementValid parentProcessFencingIndependentlyRequired', 'report')
    same(value['schema'], SCHEMA, 'report schema'); same(value['type'], 'report', 'report type')
    same(value['admission'], first, 'Repeated exact admission')
    for key in ('completed', 'targetOwnerReleased', 'assistantOwnerReleased', 'verifiedFileOwnerReleased',
                'cacheClearCompleted', 'targetLoadReceiptPreserved', 'additionalBuffersCheckedAtMaterialization',
                'parentProcessFencingIndependentlyRequired'):
        same(value[key], True, key)
    for key in ('collectiveInitialized', 'bilateralAdmissionPerformed', 'forwardExecuted', 'requestStateCreated',
                'generationEnabled', 'tensorValuesIndependentlyCompared', 'numericalParityEstablished',
                'pairwiseBufferAddressesIndependentlyCompared', 'providerEligibilityEstablished', 'throughputMeasurementValid'):
        same(value[key], False, key)
    payload = fields(value['payload'], 'targetLoad mtpLoad loadedResources loadedMemory', 'payload')
    target = validated_load(payload['targetLoad'], control['target'])
    mtp_load(payload['mtpLoad'], target, control)
    deadline = expected['deadlineUptimeNanoseconds']
    os_observation(payload['loadedResources'], deadline); os_observation(value['releasedResources'], deadline)
    require(first['initialResources']['completedNanoseconds'] <= payload['loadedResources']['startedNanoseconds']
            <= payload['loadedResources']['completedNanoseconds'] <= value['releasedResources']['startedNanoseconds'],
            'Native observation phase order differs')
    memory(value['initialMemory'], 'before_selected_mtp_load')
    memory(payload['loadedMemory'], 'selected_mtp_loaded', True)
    memory(value['releasedMemory'], 'selected_mtp_released', True)
    require(payload['loadedMemory']['activeMLXBytes'] >= 3979190464 + 709010432,
            'Active allocator bytes do not cover selected resident tensors')
    require(value['initialMemory']['peakMLXBytesSinceProcessStart'] <= payload['loadedMemory']['peakMLXBytesSinceProcessStart']
            <= value['releasedMemory']['peakMLXBytesSinceProcessStart'], 'Allocator peak went backwards')
    runtime(value['runtime'], pid, deployment)
    return value
