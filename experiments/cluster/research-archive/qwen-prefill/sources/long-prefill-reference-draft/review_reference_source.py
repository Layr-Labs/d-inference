#!/usr/bin/env python3
"""Read-only source/metadata audit; no subprocess, model payload or MLX."""
from pathlib import Path
import hashlib
import json

ROOT = Path('/Users/developer/DarkbloomDev')
DRAFT = ROOT / 'cluster-research/long-prefill-reference-draft'
SOURCE = ROOT / 'd-inference/experiments/cluster/inference/Sources/ClusterInference'
FILES = ['QwenLongPrefillReferenceAdmission.swift', 'QwenLongPrefillReferenceEvidence.swift',
         'QwenLongPrefillReferenceCapture.swift', 'QwenLongPrefillReferenceRequest.swift',
         'QwenLongPrefillReferenceProducer.swift', 'QwenLongPrefillReferenceAdmissionCheck.swift']
DEPENDENCIES = ['VerifiedQwenLayerStageBaseline.swift', 'VerifiedQwenDiagnosticLoading.swift',
                'PreparedQwenCheckpoint.swift', 'CBv2RequestSession.swift', 'CBv2RequestGeometry.swift',
                'CBv2OwnedStateSnapshot.swift', 'QwenLayerStageRecordedLogits.swift',
                'QwenLayerStageRecordedEvidence.swift', 'QwenLayerStageProfiledPrefillRequestSpec.swift',
                'QwenLayerStageProfiledPrefillRecordedRequest.swift', 'QwenLayerStageAdmittedSchedule.swift',
                'QwenLayerStageAdmittedRequest.swift', 'QwenLayerStagePrefillProfile.swift',
                'QwenLongPrefillTensorBudget.swift', 'QwenRegistered9BLongPrefillAdmission.swift',
                'QwenLongPrefillArithmeticEnvironment.swift', 'QwenLayerStagePlan.swift',
                'QwenLayerStageMetadata.swift', 'QwenLayerStageSoloPrefillResult.swift',
                'WorkerJSONScanner.swift', 'LocalCorrectnessStorage.swift']
METAL = ROOT / 'd-inference/libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/arg_reduce.metal'
QWEN = ROOT / 'd-inference/libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift'
BUDGET_AUDIT = ROOT / 'cluster-research/long-prefill-budget-draft/cpu-audit.json'
BUDGET_SHA = '6c62b336806059e5b4ba5047ca00773d52d3d3e5693aa739b64d3951a75cd7e6'


def pin(path):
    data = path.read_bytes()
    return {'path': str(path), 'byteCount': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def main():
    paths = [Path(__file__), DRAFT / 'HANDOFF.md'] + [DRAFT / n for n in FILES] + [SOURCE / n for n in DEPENDENCIES] + [METAL, QWEN, BUDGET_AUDIT]
    before = [pin(p) for p in paths]
    assert pin(BUDGET_AUDIT)['sha256'] == BUDGET_SHA
    budget = json.loads(BUDGET_AUDIT.read_bytes())
    assert budget['status'] == 'passed'
    assert budget['sourceDerivedNativeGeometry']['fullCommittedLogicalStateBytes'] == 319946784
    text = {n: (DRAFT / n).read_text() for n in FILES}
    for name, source in text.items():
        for forbidden in ('/Users/', '100.109.', 'ssh ', 'import Dispatch', 'DispatchTime', 'Options', 'loadModel(', 'loadVerifiedQwenLayerStage('):
            # Comments can explain the absence of Options; inspect code lines.
            code = '\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('//'))
            assert forbidden not in code, (name, forbidden)
    admission, evidence, capture, request, producer, fixture = [text[n] for n in FILES]
    assert admission.index('sha256(promptData) == expectedPromptSHA256') < admission.index('JSONDecoder().decode([Int].self')
    assert admission.index('validateWorkerJSON(promptData)') < admission.index('JSONDecoder().decode([Int].self')
    assert 'request.promptCount == 8192, request.chunkSize == 512' in admission
    assert 'recorded.steps.enumerated().allSatisfy' in admission
    assert 'arithmetic == canonicalArithmetic' in admission
    assert 'sha256(try canonicalJSONData(arithmetic))' in admission
    assert 'arithmeticEnvironmentSHA256: admission.arithmeticEnvironmentSHA256' in capture
    assert 'receipt.tensorCount == 927, receipt.sourceTensorCount == 927' in capture
    assert capture.count('argMax(logits)') == 1
    assert capture.count('QwenRecordedLogits(logits,') == 1
    assert 'token == firstMaximum' in capture and 'values.reduce(0)' in capture
    assert request.count('CBv2RequestSession(') == 1 and request.count('fresh.prefillChunk(') == 1
    assert request.count('fresh.snapshot(') == 1 and 'includeBytes: false' in request
    assert request.index('fresh.snapshot(') > request.index('commits.count == 16')
    assert 'snapshot(' not in request[request.index('for step in admission.request.steps'):request.index('commits.count == 16')]
    assert 'finalLogits = nil\n            try fresh.close()' in request
    assert 'if let session, !retiredCleanly' in request
    assert request.index('retiredCleanly = true') < request.index('try checked()', request.index('retiredCleanly = true'))
    assert producer.count('loadVerifiedQwenLayerStageBaseline(') == 1
    assert producer.index('guard model == nil') > producer.index('return try runQwenLongPrefillReferenceRequest(')
    assert 'weak var model: Module?' in producer
    assert 'model: Module' not in evidence and 'MLXArray' not in evidence and '() throws' not in evidence
    assert 'maximumLogit.bitPattern' in evidence
    assert 'let perFrameStateCaptures = 0, perFrameLogitCaptures = 0' in evidence
    assert 'let finalStateCaptures = 1, finalLogitCaptures = 1, nativeTokenSelections = 1' in evidence
    assert 'let candidateNumericalComparisonPerformed = false' in evidence
    assert 'try session.cancel(); try cleanupError.check()' in request
    assert 'try check()' not in producer[producer.index('} catch {'):]
    shared = (SOURCE / 'QwenLayerStageRecordedLogits.swift').read_text()
    assert 'array.asData(access: .copy).data' in shared and 'private let logicalBytes: Data' in shared
    assert 'values.allSatisfy(\\.isFinite)' in shared
    snapshot = (SOURCE / 'CBv2OwnedStateSnapshot.swift').read_text()
    assert 'bytes: includeBytes ? bytes : nil' in snapshot
    owner = (SOURCE / 'CBv2RequestSession.swift').read_text()
    assert 'eval([output] + roots + cacheRoots)' in owner and 'try validateState(after:' in owner
    assert 'return hidden[0..., -1, 0 ..< 1]' in QWEN.read_text()
    assert '(best.val == current.val && best.index > current.index)' in METAL.read_text()
    after = [pin(p) for p in paths]
    assert before == after
    report = {'kind': 'qwen_registered9b_long_prefill_reference_source_review', 'schemaVersion': 1,
              'status': 'source_draft_ready_no_execution', 'inputsUnchanged': True, 'inputs': before,
              'staticStructureAssertionsPassed': True,
              'independentCleanupReview': {'reviewer': 'transport_probe', 'blockersReported': [], 'executionPerformed': False},
              'prospectiveSwiftAdmissionCheck': {'entry': 'checkQwenLongPrefillReferenceAdmission(configuration:)',
                                               'executionPerformed': False},
              'expectedGeometryBoundToFrozenPriorCPUOnlyMetadata': budget['sourceDerivedNativeGeometry'],
              'scope': {'swiftBuildOrExecutionPerformed': False, 'nativeInferencePerformed': False,
                        'modelPayloadRead': False, 'referenceProduced': False, 'performanceMeasured': False,
                        'resourceAdmissionOrFailureCleanupQualifiedByExecution': False},
              'requiredNextGates': ['root compile and pure admission fixture', 'independent prospective output oracle',
                                    'frozen natural8192-token input and OS admission',
                                    'root-only native same-chunk reference plus retained failure cleanup evidence']}
    print(json.dumps(report, indent=2, sort_keys=True, allow_nan=False))


if __name__ == '__main__':
    main()
