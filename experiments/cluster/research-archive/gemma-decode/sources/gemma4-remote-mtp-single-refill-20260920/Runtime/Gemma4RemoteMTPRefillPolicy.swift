import Foundation

/// Controls only the EXPOSED synchronous refill. The actual ledger still grants
/// at most two, buffers at most five and decides credit/retirement. Overlapped
/// lookahead remains two so a matching target bonus leaves a ready proposal.
enum Gemma4RemoteMTPRefillPolicy: String {
    case paired = "paired_v1"
    case singleForDepthOne = "single_for_depth_one_v1"
    enum Failure: Error { case policyOrDepth, unavailableCredit }

    init(explicitPolicy: String?, verificationDepth: Int) throws {
        guard (1...2).contains(verificationDepth) else { throw Failure.policyOrDepth }
        guard let explicitPolicy else { self = .paired; return }
        guard explicitPolicy == Self.singleForDepthOne.rawValue, verificationDepth == 1 else {
            throw Failure.policyOrDepth
        }
        self = .singleForDepthOne
    }

    var scopeComponents: [String] {
        self == .paired ? [] : ["producerRefillPolicy=" + rawValue, "producerLookaheadGrant=2"]
    }

    func exposedGrant(draftCount: Int, proposalCredit: Int) throws -> Int {
        if self == .paired { return min(2, proposalCredit) } // Exact old expression.
        guard draftCount == 1 else { throw Failure.policyOrDepth }
        guard (1...2).contains(proposalCredit) else { throw Failure.unavailableCredit }
        return 1
    }
}
