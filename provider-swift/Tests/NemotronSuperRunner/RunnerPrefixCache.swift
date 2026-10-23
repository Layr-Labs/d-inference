import MLXLMCommon
@testable import ProviderCore

/// Counters of the owner's resident checkpoint bank, so a cold/warm run can
/// tell restored prefill from cold prefill: `adoptions` and `tokens_saved`
/// rise once per restored request. `null` when the owner has no bank.
enum RunnerPrefixCache {
    static func json(_ bridge: EngineV2Bridge) async -> RunnerJSON {
        guard let bank = (await bridge.ownedEngine as? EngineV2)?.hybridPrefixCache else { return .null }
        let stats = bank.stats
        return [
            "maximum_bytes": .bytes(bank.config.maximumBytes),
            "retained_bytes": .bytes(stats.retainedBytes), "resident_bytes": .bytes(stats.residentBytes),
            "entries": .count(stats.entries), "checkpoints": .count(stats.checkpoints),
            "lookup_matches": .count(stats.lookupMatches), "misses": .count(stats.misses),
            "adoptions": .count(stats.adoptions), "tokens_saved": .count(stats.tokensSaved),
            "capacity_refusals": .count(stats.capacityRefusals), "evictions": .count(stats.evictions),
        ]
    }
}
