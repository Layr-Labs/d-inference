import Foundation

/// Greedy proposal policy only. It grants no target publication or native authority.
struct AsyncMTPBonusContinuationPolicy: Equatable, Sendable {
    static let name = "bounded_stale_bonus_v1"
    static let strict = Self(verificationDepth: 0)
    static let maximumWindows = 16
    static let maximumPositions = 32
    let verificationDepth: Int
    var enabled: Bool { verificationDepth != 0 }
    private init(verificationDepth: Int) { self.verificationDepth = verificationDepth }
    init(explicitPolicy: String?, verificationDepth: Int) throws {
        guard (1...2).contains(verificationDepth) else { throw Failure.invalidPolicy }
        if explicitPolicy == nil { self = .strict; return }
        guard explicitPolicy == Self.name else { throw Failure.invalidPolicy }
        self.init(verificationDepth: verificationDepth)
    }
    enum Failure: Error { case invalidPolicy }
    var scopeComponents: [String] {
        enabled ? ["bonusContinuationPolicy=" + Self.name,
            "bonusContinuationWindows=16", "bonusContinuationPositions=32"] : []
    }
}

/// Scalar control observations. These do not prove target math or GPU overlap.
struct AsyncMTPBonusContinuationReport: Encodable, Equatable {
    let policy = AsyncMTPBonusContinuationPolicy.name
    let maximumWindows = AsyncMTPBonusContinuationPolicy.maximumWindows
    let maximumPositions = AsyncMTPBonusContinuationPolicy.maximumPositions
    let verificationDepth: Int
    let epochsStarted: Int, bonusMismatchesContinued: Int
    let boundRetirementDecisions: Int, noReadyRetirementDecisions: Int
    let maximumObservedWindows: Int, maximumObservedInputAdvance: Int
    let maximumObservedProducedAdvance: Int
    let targetVerificationBypassed = false
    let assistantDistributionEquivalenceClaimed = false
}
