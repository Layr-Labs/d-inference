import Foundation

/// Chosen target verification width within the unchanged k2/five-slot producer
/// envelope. This value grants no model, KV, transport or resource capacity.
struct Gemma4RemoteMTPDepth: Equatable {
    struct Failure: Error { let reason: String }
    let maximumDraftTokens: Int
    var scopeComponent: String { "depth=\(maximumDraftTokens)" }

    init(maximumDraftTokens: Int) throws {
        guard (1...2).contains(maximumDraftTokens) else {
            throw Failure(reason:"Remote MTP verification depth must be one or two")
        }
        self.maximumDraftTokens = maximumDraftTokens
    }
    func draftCount(remainingOutputTokens: Int) throws -> Int {
        guard remainingOutputTokens >= 2 else {
            throw Failure(reason:"Remote MTP verification requires a draft and confirmed output slot")
        }
        return min(maximumDraftTokens,remainingOutputTokens-1)
    }
}
