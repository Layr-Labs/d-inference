import Foundation
import Testing
@testable import ProviderCore

private extension ProviderLoop {
    func seedAutopilotStartupHash(_ hash: String?) {
        modelHashes = hash.map { ["target": $0] } ?? [:]
        liveModelHashes = modelHashes
    }
}

@Suite("Autopilot exact-build load history")
struct ModelAutopilotHistoryTests {
    @Test(arguments: [false, true])
    func refreshedHashOwnsMeasurement(hadStartupHash: Bool) async throws {
        let loop = try await autopilotTestLoop(enabled: false)
        let oldHash = String(repeating: "a", count: 64)
        let liveHash = String(repeating: "b", count: 64)
        await loop.seedAutopilotStartupHash(hadStartupHash ? oldHash : nil)
        await loop.publishWeightHash(modelId: "target", snapshot: .init(
            fingerprint: "refreshed", hash: liveHash, recomputed: true))
        await loop.recordAutopilotLoadTime(model: "target", milliseconds: 1_200)
        let history = await loop.autopilotTimingHistory
        #expect(history.loads.count == 1)
        #expect(history.loads.first?.weightHash == liveHash)
        #expect(history.loads.first?.loadMs == 1_200)
    }
}
