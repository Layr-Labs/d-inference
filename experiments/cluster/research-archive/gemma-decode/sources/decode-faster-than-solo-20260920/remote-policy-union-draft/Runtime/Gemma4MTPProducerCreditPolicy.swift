import Foundation

/// Scalar transport credit is distinct from the unchanged <=2 native batch.
/// This policy is private, opt-in and restricted to chosen verification D2.
enum Gemma4MTPProducerCreditPolicy: String {
    case legacy = "two_proposal_credit_v1"
    case threeForDepthTwo = "three_for_depth_two_v1"
    struct Failure: Error { let reason: String }
    init(explicit: String?, verificationDepth: Int) throws {
        guard (1...2).contains(verificationDepth) else { throw Failure(reason:"Invalid verification depth") }
        guard let explicit else { self = .legacy; return }
        guard explicit == Self.threeForDepthTwo.rawValue, verificationDepth == 2 else {
            throw Failure(reason:"Three-proposal credit requires explicit chosen D2")
        }
        self = .threeForDepthTwo
    }
    var maximumProducerGrantTokens: Int { self == .legacy ? 2 : 3 }
    var scopeComponents: [String] {
        self == .legacy ? [] : ["producerCreditPolicy="+rawValue,"maximumProducerCredit=3","nativeProducerBatchLimit=2"]
    }
    func lookaheadCount(availableCredit: Int) throws -> Int {
        guard (1...maximumProducerGrantTokens).contains(availableCredit) else { throw Failure(reason:"Unavailable producer credit") }
        return min(maximumProducerGrantTokens,availableCredit)
    }
    func nativeBatchCounts(for credit: Int) throws -> [Int] {
        guard (1...maximumProducerGrantTokens).contains(credit) else { throw Failure(reason:"Producer credit exceeds explicit policy") }
        return credit == 3 ? [2,1] : [credit]
    }
}
