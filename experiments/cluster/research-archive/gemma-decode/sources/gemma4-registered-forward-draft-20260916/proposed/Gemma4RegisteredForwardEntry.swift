import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Concrete full/staged native entry for a separately admitted correctness
/// operation. The callbacks are obligations, not caller-asserted capacity:
/// no public CLI/SPI is added until a closed Gemma resource owner implements
/// all four gates and binds the actual probe/boundary terms.
func withRegisteredGemma4Forward(
    directory: URL, artifact: Gemma4ArtifactMetadata, cut: Int,
    target: Gemma4ForwardTarget, request: QwenLayerStageGenerationRequest,
    residualDType: DType,
    admitConstruction: ([Gemma4SelectedTensor]) throws -> Void,
    beforeTensor: (Gemma4SelectedTensor) throws -> Void,
    admitLoadedProbe: (Gemma4ForwardLoadReceipt) throws -> Void,
    admitRequest: (CBv2RequestGeometry) throws -> Void,
    probeInput: ((CBv2NativeKVTypeProbe.Phase, Int) throws -> MLXArray)? = nil,
    observeProbeOutput: ((CBv2NativeKVTypeProbe.Phase, MLXArray) throws -> Void)? = nil,
    check: () throws -> Void,
    body: (Gemma4OwnedForwardSession) throws -> Data
) throws -> Data {
    weak var retiredModel: Module?
    do {
        return try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            do {
                try checked(); try Gemma4ForwardRequest.validate(request, dtype: residualDType)
                let result = try autoreleasepool {
                    let source = try Gemma4RegisteredSource.prepare(directory: directory,
                        artifact: artifact, cut: cut, check: checked)
                    let selected = try source.selection(target)
                    try admitConstruction(selected); try checked()
                    let prepared = try Gemma4PreparedForwardModel.prepare(source: source,
                        target: target, check: checked)
                    retiredModel = prepared.model.module
                    let loaded = try materializeRegisteredGemma4(prepared,
                        beforeTensor: beforeTensor, check: checked)
                    try admitLoadedProbe(loaded.receipt); try checked()
                    let probe = try loaded.probe(incomingDType: loaded.model.isResidualConsumer ? residualDType : nil,
                        incoming: probeInput, observeIngress: observeProbeOutput, check: checked)
                    try checked()
                    let session = try Gemma4OwnedForwardSession(loaded: loaded, request: request,
                        probe: probe, residualDType: residualDType, admitGeometry: admitRequest, check: checked)
                    do {
                        let value = try body(session)
                        guard session.isClosed, !session.isFailed else {
                            throw ProbeError("Gemma correctness body did not finish healthy request retirement")
                        }
                        try checked()
                        return value
                    } catch {
                        let primary = error
                        do { try session.cancel() }
                        catch { throw ProbeError("Gemma correctness failed (\(primary)); cancellation failed (\(error))") }
                        throw primary
                    }
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard retiredModel == nil else { throw ProbeError("Gemma model escaped the bounded forward scope") }
                Memory.clearCache(); try checked()
                return result
            } catch { try native.check(); throw error }
        }
    } catch {
        let primary = error
        var failures: [String] = []
        do {
            try MLX.withError { native in
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache(); try native.check()
            }
        } catch { failures.append(String(describing: error)) }
        if retiredModel != nil { failures.append("model remains retained") }
        guard failures.isEmpty else {
            throw ProbeError("Gemma forward failed (\(primary)); cleanup: \(failures.joined(separator: "; "))")
        }
        throw primary
    }
}
