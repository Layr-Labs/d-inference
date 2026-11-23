import MLXLMCommon

/// What a request's `RequestCachePolicy` changes in one submission, decided
/// in one place.
///
/// A `memory_only` text request keeps its prefix cache only on a slot with a
/// RAM-only tier (`MemoryOnlyCheckpointTier`), which is attached to single-Mac
/// complete-checkpoint slots without an engine-resident tier. Everywhere else
/// it runs with its cache off: the SSD tier is closed to it, and the
/// engine-resident tiers (resident blocks, the recurrent bank, a pair's ranks)
/// keep prefixes without the TTL and wipe a `memory_only` request needs. Either
/// way its receipt is minted in the memory-only range (`MemoryOnlyReceipt`), so
/// the SSD store hands every engine call made for it to the RAM-only tier, or
/// refuses it, and the bridge never registers SSD ready receipts or a donation
/// demand hint for it.
struct PrefixCacheSubmissionPolicy: Sendable, Equatable {
    let cachePolicy: RequestCachePolicy
    /// The slot has a RAM-only tier and the request is text on a single Mac.
    var memoryOnlyTierAvailable = false

    /// Stage, ready receipts and the donation demand hint use the SSD tier.
    var usesSSDTier: Bool { cachePolicy.permitsSSDTier }

    /// Stage and donation use the slot's RAM-only tier.
    var usesMemoryOnlyTier: Bool { !usesSSDTier && memoryOnlyTierAvailable }

    func cacheEnabled(_ requested: Bool) -> Bool { requested && (usesSSDTier || usesMemoryOnlyTier) }
}
