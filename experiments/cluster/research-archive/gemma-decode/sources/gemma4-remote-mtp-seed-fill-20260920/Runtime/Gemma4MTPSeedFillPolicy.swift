import Foundation

/// Private explicit wire policy. It changes exposed seed/refill sequencing only;
/// the ordinary two-proposal producer batch and five-slot ledger remain exact.
enum Gemma4MTPSeedFillPolicy: String {
    case legacy = "separate_seed_and_fill_v1"
    case completedInitialProposals = "completed_initial_proposals_v1"
    struct Failure: Error { let reason: String }

    init(explicit: String?) throws {
        guard let explicit else { self = .legacy; return }
        guard explicit == Self.completedInitialProposals.rawValue else {
            throw Failure(reason: "Unknown explicit seed-fill policy")
        }
        self = .completedInitialProposals
    }
    var scopeComponents: [String] {
        self == .legacy ? [] : ["seedFillPolicy=" + rawValue]
    }
    func initialGrant(draftCount: Int?, proposalCredit: Int) throws -> Int? {
        if self == .legacy {
            guard draftCount == nil else { throw Failure(reason: "Legacy seed cannot grant proposals") }
            return nil
        }
        guard let draftCount, (1...2).contains(draftCount), (1...2).contains(proposalCredit),
              draftCount <= proposalCredit else {
            throw Failure(reason: "Seed-fill exceeds the chosen next window or actual credit")
        }
        // Preserve the old fill's min(2, credit), including its D1 batch width.
        return min(2, proposalCredit)
    }
}
