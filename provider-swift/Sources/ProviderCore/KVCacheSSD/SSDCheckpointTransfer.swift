import Foundation
import MLXLMCommon

/// One encrypted storage pipeline, explicit architecture-specific native
/// destinations. No diffusion state is represented as an AR recurrent state.
enum SSDCheckpointImportPlan {
    case autoregressive(CBv2CompleteCheckpointImportPlan)
    case nativeBlock(CBv2NativeBlockCheckpointImportPlan)

    var nativeDestinationBytes: Int {
        switch self { case .autoregressive(let plan): plan.nativeDestinationBytes; case .nativeBlock(let plan): plan.nativeDestinationBytes }
    }
    var scratchBytes: Int {
        switch self { case .autoregressive(let plan): plan.scratchBytes; case .nativeBlock(let plan): plan.scratchBytes }
    }
    var usesProcessMemoryOwner: Bool {
        switch self { case .autoregressive(let plan): plan.usesProcessMemoryOwner; case .nativeBlock(let plan): plan.usesProcessMemoryOwner }
    }
    func allocate(onRelease: @escaping @Sendable () -> Void) throws -> SSDCheckpointImport {
        switch self {
        case .autoregressive(let plan): return .autoregressive(try plan.allocate(onRelease: onRelease))
        case .nativeBlock(let plan): return .nativeBlock(try plan.allocate(onRelease: onRelease))
        }
    }
}

enum SSDCheckpointImport {
    case autoregressive(CBv2CompleteCheckpointImport)
    case nativeBlock(CBv2NativeBlockCheckpointImport)
    func appendSegment(tensorIndex: Int, byteOffset: Int, data: Data) throws {
        switch self {
        case .autoregressive(let transfer): try transfer.appendSegment(tensorIndex: tensorIndex, byteOffset: byteOffset, data: data)
        case .nativeBlock(let transfer): try transfer.appendSegment(tensorIndex: tensorIndex, byteOffset: byteOffset, data: data)
        }
    }
    func finish() throws -> SSDCheckpointStage {
        switch self { case .autoregressive(let transfer): return .autoregressive(try transfer.finish()); case .nativeBlock(let transfer): return .nativeBlock(try transfer.finish()) }
    }
    func close() {
        switch self { case .autoregressive(let transfer): transfer.close(); case .nativeBlock(let transfer): transfer.close() }
    }
}

enum SSDCheckpointStage: Sendable {
    case autoregressive(CBv2StagedCompleteCheckpoint)
    case nativeBlock(CBv2NativeBlockCheckpoint)
    var manifest: CBv2CompleteCheckpointManifest {
        switch self { case .autoregressive(let stage): stage.manifest; case .nativeBlock(let stage): stage.manifest }
    }
    var maximumSequenceLength: Int {
        switch self { case .autoregressive(let stage): stage.maximumSequenceLength; case .nativeBlock(let stage): stage.maximumSequenceLength }
    }
    var nativeDestinationBytes: Int {
        switch self { case .autoregressive(let stage): stage.nativeDestinationBytes; case .nativeBlock(let stage): stage.nativeDestinationBytes }
    }
    var isNative: Bool { if case .nativeBlock = self { return true }; return false }
    func close() {
        switch self { case .autoregressive(let stage): stage.close(); case .nativeBlock(let stage): stage.close() }
    }
}
