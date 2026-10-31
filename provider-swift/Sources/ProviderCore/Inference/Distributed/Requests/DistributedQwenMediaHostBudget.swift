import Foundation

/// Installed distributed listeners in one process share host admission across
/// native generations. This ledger charges local preprocessing/wire buffers;
/// each worker separately admits its complete native text/media quote.
enum DistributedQwenMediaHostBudget {
    static let shared = GlobalKVCacheBudget()
}
