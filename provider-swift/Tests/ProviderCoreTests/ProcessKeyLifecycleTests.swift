import Foundation
import Testing

@testable import ProviderCore

private final class ProcessKeyFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0
    private let makeKey: @Sendable () -> NodeKeyPair

    init(makeKey: @escaping @Sendable () -> NodeKeyPair) {
        self.makeKey = makeKey
    }

    func call() -> NodeKeyPair {
        lock.lock()
        countStorage += 1
        lock.unlock()
        return makeKey()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countStorage
    }
}

private func processKeyLoop(
    factory: @escaping @Sendable () -> NodeKeyPair = NodeKeyPair.generate
) throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
            chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546
        ),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "process-key-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(
        config: config,
        purgeLegacyFiles: false,
        attestationSigner: nil,
        nodeKeyFactory: factory
    )
}

@Test func processKeyGenerationIsStrictlyAfterHardening() async throws {
    let deterministic = try NodeKeyPair(rawSecret: Data(repeating: 0x11, count: 32))
    let recorder = ProcessKeyFactoryRecorder { deterministic }
    let loop = try processKeyLoop(factory: { recorder.call() })

    #expect(await loop.keyPair == nil)
    await #expect(throws: ProviderLoopError.self) {
        try await loop.initializeProcessKeyAfterHardening()
    }
    #expect(recorder.count == 0)

    try await loop.completeSecurityHardeningForProcess()
    try await loop.initializeProcessKeyAfterHardening()
    #expect(recorder.count == 1)
    #expect(await loop.keyPair.publicKeyBase64 == deterministic.publicKeyBase64)
}

@Test func sameProcessReconnectRetainsOneProcessKey() async throws {
    let recorder = ProcessKeyFactoryRecorder { NodeKeyPair.generate() }
    let loop = try processKeyLoop(factory: { recorder.call() })
    try await loop.completeSecurityHardeningForProcess()
    try await loop.initializeProcessKeyAfterHardening()
    let first = await loop.keyPair.publicKeyBase64

    // CoordinatorClient reconnects inside this same ProviderLoop. Re-entering
    // the key initialization seam must retain the process key.
    try await loop.initializeProcessKeyAfterHardening()
    let second = await loop.keyPair.publicKeyBase64
    #expect(first == second)
    #expect(recorder.count == 1)
}

@Test func distinctProcessLaunchesCreateDistinctProcessKeys() async throws {
    let firstLoop = try processKeyLoop()
    let secondLoop = try processKeyLoop()
    try await firstLoop.completeSecurityHardeningForProcess()
    try await secondLoop.completeSecurityHardeningForProcess()
    try await firstLoop.initializeProcessKeyAfterHardening()
    try await secondLoop.initializeProcessKeyAfterHardening()
    #expect(await firstLoop.keyPair.publicKeyBase64 != secondLoop.keyPair.publicKeyBase64)
}
