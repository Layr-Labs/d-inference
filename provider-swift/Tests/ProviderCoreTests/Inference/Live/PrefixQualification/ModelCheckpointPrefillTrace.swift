import Foundation
@testable import MLXLMCommon

struct ModelCheckpointPrefillRange: Codable, Sendable, Equatable {
    let lowerBound: Int
    let upperBound: Int
    let plannedCap: Int?
    let packed: Bool

    enum Failure: Error, Equatable {
        case missingRanges, invalidRange, incompletePrompt, chunkCount, packedOrPreempted
    }

    static func validate(_ ranges: [Self], promptTokens: Int, prefillChunks: UInt32,
                         packedPrefillChunks: UInt32, preemptions: UInt32) throws {
        guard !ranges.isEmpty else { throw Failure.missingRanges }
        guard packedPrefillChunks == 0, preemptions == 0 else { throw Failure.packedOrPreempted }
        guard ranges.count == Int(prefillChunks) else { throw Failure.chunkCount }
        var position = 0
        for range in ranges {
            guard !range.packed, range.lowerBound == position, range.lowerBound >= 0,
                range.upperBound > range.lowerBound, range.upperBound <= promptTokens,
                range.plannedCap.map({ $0 > 0 && range.upperBound - range.lowerBound <= $0 }) ?? true
            else { throw Failure.invalidRange }
            position = range.upperBound
        }
        guard position == promptTokens else { throw Failure.incompletePrompt }
    }
}

/// One fixture-owned observer; ending a request never waits for the engine queue.
/// The weak callback remains inert between requests and after fixture teardown.
final class ModelCheckpointPrefillTrace: @unchecked Sendable {
    private struct Capture {
        let token: UUID
        let requestID: CBv2RequestID
        let promptTokens: Int
        var ranges: [ModelCheckpointPrefillRange] = []
    }

    private let lock = NSLock()
    private var active: Capture?

    init(engine: EngineV2) throws {
        let loop = engine.loopForTesting
        try loop.onEngineQueueSync {
            guard loop.recurrentGeometryObserverForTesting == nil else {
                throw ModelCheckpointDonationControl.Failure.observerAlreadyInstalled
            }
            loop.recurrentGeometryObserverForTesting = { [weak self] id, range, cap, packed, phase, _ in
                guard let self, phase == "range" else { return }
                self.lock.withLock {
                    guard self.active?.requestID == id, let promptTokens = self.active?.promptTokens,
                        range.lowerBound < promptTokens else { return }
                    // Keep an overrun intact so validation rejects it instead of hiding it.
                    self.active?.ranges.append(.init(lowerBound: range.lowerBound, upperBound: range.upperBound,
                        plannedCap: cap, packed: packed))
                }
            }
        }
    }

    func begin(requestID: CBv2RequestID, promptTokens: Int) throws -> UUID {
        try lock.withLock {
            guard active == nil else { throw ModelCheckpointDonationControl.Failure.observerAlreadyInstalled }
            let token = UUID()
            active = Capture(token: token, requestID: requestID, promptTokens: promptTokens)
            return token
        }
    }

    func end(_ token: UUID) {
        lock.withLock {
            if active?.token == token { active = nil }
        }
    }

    func snapshot(_ token: UUID) -> [ModelCheckpointPrefillRange] {
        lock.withLock { active?.token == token ? active?.ranges ?? [] : [] }
    }
}
