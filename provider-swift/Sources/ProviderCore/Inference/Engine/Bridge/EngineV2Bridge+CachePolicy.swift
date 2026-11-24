import MLXLMCommon

/// What a request's `RequestCachePolicy` changes in one submission, decided
/// in one place, so a prefix tier for `memory_only` requests attaches here.
///
/// A `memory_only` request runs with its prefix cache off on every slot. The
/// SSD tier is closed to it, and the engine-resident tiers (resident blocks,
/// the recurrent bank, a pair's ranks) keep prefixes without the TTL and wipe
/// a `memory_only` request needs. A cache left on would only capture
/// checkpoints for the SSD store to refuse. Everything below still holds if
/// it is on: the receipt is minted in the memory-only range
/// (`MemoryOnlyReceipt`), so the SSD stores refuse every engine call made
/// for it, and the bridge never stages, registers SSD ready receipts or
/// records a donation demand hint for it.
struct PrefixCacheSubmissionPolicy: Sendable, Equatable {
    let cachePolicy: RequestCachePolicy

    /// Stage, ready receipts and the donation demand hint use the SSD tier.
    var usesSSDTier: Bool { true }

    func cacheEnabled(_ requested: Bool) -> Bool { requested }
}
