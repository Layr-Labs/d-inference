"""Bounded source review only: no Swift compiler, model, process or socket."""
from pathlib import Path
import hashlib
import json
import re

FOLDER = Path(__file__).resolve().parent
SOURCE = FOLDER.parent.parent / 'd-inference/experiments/cluster/inference/Sources/ClusterInference'


def entry(path):
    raw = path.read_bytes()
    return dict(path=str(path), byteCount=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def review():
    paths = sorted(FOLDER.glob('*.swift'))
    assert len(paths) == 8
    drafts = {p.name: p.read_text() for p in paths}
    combined = '\n'.join(drafts.values())
    declared = set(re.findall(r'\b(?:class|struct|enum|typealias)\s+(\w+)', combined))
    integrated = '\n'.join(p.read_text() for p in SOURCE.glob('*.swift'))
    known = declared | set(re.findall(r'\b(?:class|struct|enum|typealias)\s+(\w+)', integrated))
    references = set(re.findall(r'\bQwenLayerStage\w+', combined))
    assert references <= known, sorted(references - known)
    assert 'QwenLayerStagePrefillStartWirePacket' not in combined
    assert 'QwenLayerStagePrefillBoundaryEnvelope' not in combined
    assert 'QwenLayerStagePrefillFirstTokenWirePacket' not in combined
    state = drafts['QwenLayerStageProfiledPrefillTransportState.swift']
    assert 'import MLX' not in state and 'MLXArray' not in state
    assert 'current.nonce == ticket.nonce' in state and 'ticket.owner == owner' in state
    assert state.count('finalBoundaryWireBytesSHA256 ==') == 2
    sender = drafts['QwenLayerStageProfiledPrefillTransportSender.swift']
    assert 'sendUntilReceived(_ prepared: QwenLayerStageProfiledPrefillPrepared' in sender
    assert 'commit.recordedRequestFingerprint == agreement.request.fingerprint' in sender
    assert 'shape: boundary.array.shape' in sender and 'header.validatePayload(bytes)' in sender
    receiver = drafts['QwenLayerStageProfiledPrefillTransportReceiver.swift']
    assert receiver.index('BoundaryEnvelope.decode') < receiver.index('io.receivePayload(expected: expected')
    assert receiver.index('boundary.validateOwnedArray') < receiver.index('try phase(.beginReceivedACK')
    assert receiver.index('let consumed = try consume(boundary)') < receiver.index('guard receivedHandle == nil')
    assert receiver.index('guard receivedHandle == nil') < receiver.index('try phase(.beginConsumedACK')
    shim = (SOURCE/'CollectivePointToPoint.swift').read_text()
    assert 'let communication = StreamOrDevice.cpu' in shim
    assert 'mlx_array_eval(array.ctx)' in shim and 'mlx_synchronize(communication.ctx)' in shim
    assert 'mlx_synchronize(gpu.ctx)' in shim and 'geometry.validateOwnedReceive(output)' in shim
    assert 'hardByteLimit = 16 * 1024 * 1024' in (SOURCE/'CollectivePointToPointShape.swift').read_text()
    fixture = drafts['QwenLayerStageProfiledNativeTransportStateCheck.swift']
    assert fixture.count('checks.reject(') == 14
    legacy = [SOURCE/('QwenLayerStagePrefill'+suffix+'.swift') for suffix in
              ['NativeIO','Transport','TransportControl','TransportReceiver','TransportSender','TransportState','TransportTypes']]
    contracts = [SOURCE/name for name in ['Collective.swift','CollectivePointToPoint.swift','CollectivePointToPointShape.swift',
        'QwenLayerStageProfiledPrefillStartAgreement.swift','QwenLayerStageProfiledPrefillBoundaryEnvelope.swift',
        'QwenLayerStageProfiledPrefillFirstTokenWirePacket.swift','QwenLayerStageProfiledBoundaryWireHeader.swift',
        'QwenLayerStageProfiledWireIdentity.swift','QwenLayerStageProfiledPrefillComputeContext.swift',
        'QwenLayerStageProfiledComputeTypes.swift','QwenLayerStageProfiledWireCheckFixture.swift']]
    return dict(kind='qwen_profiled_native_wire_source_review',schemaVersion=1,status='passed',
        sourceFiles=[entry(p) for p in paths],legacySourcesReadOnly=[entry(p) for p in legacy],
        dependencyContracts=[entry(p) for p in contracts],declaredSwiftStateRejections=14,
        swiftCompiled=False,swiftChecksExecuted=False,nativeIOExecuted=False,modelPayloadRead=False,
        candidateOutputRead=False,scope='Source identity, typed dependency and ordering assertions only')


if __name__ == '__main__':
    print(json.dumps(review(),indent=2,sort_keys=True))
