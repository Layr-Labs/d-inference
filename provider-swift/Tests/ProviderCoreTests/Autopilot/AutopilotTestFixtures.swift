import Foundation
@testable import ProviderCore

func autopilotTestLoop(enabled: Bool, models: [ModelInfo] = [], activeControl: Bool = true) async throws -> ProviderLoop {
    let loop = try ProviderLoop(config: ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/unused",
        hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546),
        models: models, config: ProviderConfig(provider: ProviderSettings(name: "autopilot-test"), backend: BackendSettings(modelAutopilot: .init(enabled: enabled, consentRecorded:true, selectedModels:["target","uncached","other"], revision:"test")))),
        attestationSigner: nil)
    if enabled && activeControl { await loop.activateAutopilotForTesting() }
    return loop
}

extension ProviderLoop {
    func activateAutopilotForTesting() {
        autopilotControl = .init(sessionId:"session", revision:"test", enabled:true,
            expiresAtMs:Int64(Date().timeIntervalSince1970*1000)+120000)
        publishModelAutopilotSnapshot()
    }
}

final class AutopilotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func append(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var statuses: [ModelAutopilotStatus] {
        lock.withLock { messages.compactMap { if case .modelAutopilotStatus(let status) = $0 { return status }; return nil } }
    }
    var legacyFailures: Int {
        lock.withLock { messages.filter { if case .loadModelStatus(_, .failed, _) = $0 { return true }; return false }.count }
    }
    var legacyStatuses: [ProviderMessage.LoadModelStatus.Status] {
        lock.withLock { messages.compactMap { if case .loadModelStatus(_, let status, _) = $0 { return status }; return nil } }
    }
}
