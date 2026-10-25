import Foundation

/// Opt-in only. One resident head serves request-local states at any admitted
/// owner capacity. A singleton policy speculates only singleton decode sets; an
/// admitted-cohort policy verifies up to its quoted width of rows in one
/// rectangle, each row its own window (`verify-rows`). The width comes from the
/// typed assistant policy, itself in the load agreement. Media keeps the
/// ordinary target path, as the standalone contract requires.
enum QwenTensorParallelMTPPolicy {
    static let agreement = "qwen27-tensor-mtp-resident-batch-v1"
    /// Rows whose artifact's inline head the replicated TP assistant loads
    /// (`QwenTensorParallelMTPInventory`). Every other TP row serves its
    /// request-owned lanes without speculation.
    static let models: Set<QwenRegisteredDenseModel> = [.qwen35NineB, .qwen38TwentySevenB]
    /// Trusted assistant history enters head K/V in blocks of at most this
    /// many rows (first draft and ordinary decode), bounding its workspace.
    static let historyFlushRows = 512
    static func require(model: QwenRegisteredDenseModel, lanes: Int, keyed: Bool, paged: Bool,
                        terms: QwenMTPTerms?, environment: [String: String]) throws {
        guard terms != nil else { return }
        guard models.contains(model), (1...8).contains(lanes), keyed, paged else {
            throw ProbeError("Qwen TP MTP requires a row with a TP assistant, bounded lanes and keyed paged ownership")
        }
        for key in ["DARKBLOOM_QWEN_MTP_SERIAL", "DARKBLOOM_QWEN_MTP_DOUBLE_FORWARD"] {
            guard !["1", "true", "yes", "on"].contains(environment[key]?.lowercased() ?? "") else {
                throw ProbeError("Qwen TP MTP does not admit alternate assistant verification graphs")
            }
        }
        guard environment["DARKBLOOM_QWEN_MTP_SHORTLIST"].map({ $0 == "0" }) ?? true else {
            throw ProbeError("Qwen TP MTP uses the complete sharded vocabulary head")
        }
    }
    static func fields(terms: QwenMTPTerms?, inventory: QwenTensorParallelMTPInventory?) throws -> [String] {
        guard let terms else {
            guard inventory == nil else { throw ProbeError("Unexpected tensor assistant inventory") }
            return []
        }
        guard let inventory else { throw ProbeError("Tensor assistant inventory is missing") }
        return [agreement, "depth=\(terms.depth)", "inventory=\(inventory.fingerprint)",
            "target=captured-rectangle", "head=rank0-hidden-sharded-vocabulary", "draft-ids=rank0",
            "assistant-kv=paged64", QwenTensorParallelMTPPrefixBudget.policy, "media=target-only", "speculative-width=assistant-policy", "decode-history=observed", "history-flush=\(historyFlushRows)", "request-ledger=rank-heads-v1", "verify-rows=single-window-v1", "accepted-credit=bounded-suffix-v1", "shortlist=off"]
    }
}
